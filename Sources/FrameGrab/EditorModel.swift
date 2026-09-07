import SwiftUI
import Combine
import AVFoundation
import CoreMedia
import AppKit
import UniformTypeIdentifiers

/// Single source of truth for the editor: the loaded video, the player, the
/// in/out selection, export settings and export progress.
///
/// Deliberately *not* annotated `@MainActor` — it is driven from SwiftUI (main
/// thread) and from AVFoundation callbacks, and we marshal every published
/// mutation back to the main queue explicitly. This keeps it buildable against
/// the macOS 13 deployment target without `MainActor.assumeIsolated`.
final class EditorModel: ObservableObject {

    // Player / asset
    let player = AVPlayer()
    @Published private(set) var asset: AVURLAsset?
    @Published private(set) var videoURL: URL?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false

    // Selection (seconds)
    @Published var selectionStart: Double = 0
    @Published var selectionEnd: Double = 0

    // Timeline filmstrip
    @Published private(set) var thumbnails: [NSImage] = []

    // Export settings + state
    @Published var settings = ExportSettings()
    /// What the user typed into the export **Name** field. Empty means "use the
    /// video's own name" — the field shows that fallback as its placeholder.
    /// Deliberately kept out of `ExportSettings`, which drives the frame-timing
    /// pipeline: renaming an export must never rebuild the preview or discard
    /// hand-picked frame exclusions.
    @Published var exportName: String = ""
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0

    // Frame preview
    /// Exact timestamps the exporter will sample, before exclusions. Recomputed
    /// whenever the selection or the frame settings change.
    @Published private(set) var plannedTimes: [Double] = []
    @Published private(set) var previewFrames: [PreviewFrame] = []
    @Published private(set) var excludedFrameIDs: Set<Int> = []
    @Published private(set) var isPreviewVisible = false
    @Published private(set) var isGeneratingPreview = false

    /// Rendering hundreds of thumbnails is pointless (and slow) — cap the grid.
    static let maxPreviewFrames = 60

    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var exportTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Identifies the current load so stale async work (e.g. thumbnails from a
    /// previously-opened video) can be discarded.
    private var loadToken = UUID()

    init() {
        addTimeObserver()

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
            .store(in: &cancellables)

        // Keep the planned frame list in sync with the selection + settings.
        Publishers.CombineLatest3($selectionStart, $selectionEnd, $settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.recomputePlannedTimes()
            }
            .store(in: &cancellables)
    }

    deinit {
        previewTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    // MARK: - Derived values

    var selectionDuration: Double { max(0, selectionEnd - selectionStart) }

    /// How many frames the current settings produce, before exclusions.
    var plannedFrameCount: Int { plannedTimes.count }

    /// How many frames will actually be written (exclusions applied).
    var includedFrameCount: Int { max(0, plannedTimes.count - excludedFrameIDs.count) }

    /// Timestamps that will actually be exported, in order.
    var exportTimes: [Double] {
        guard !excludedFrameIDs.isEmpty else { return plannedTimes }
        return plannedTimes.enumerated()
            .filter { !excludedFrameIDs.contains($0.offset) }
            .map(\.element)
    }

    /// True when the planned set is larger than the preview grid can show.
    var previewIsTruncated: Bool { plannedTimes.count > Self.maxPreviewFrames }

    /// The name used when the user hasn't typed one: `<video>_frames`.
    var defaultExportName: String {
        guard let stem = videoURL?.deletingPathExtension().lastPathComponent,
              !stem.isEmpty else { return "frames" }
        return "\(stem)_frames"
    }

    /// The name the export will actually use — the typed one, made safe for the
    /// file system, or the default when the field is blank.
    var resolvedExportName: String {
        ExportNaming.sanitize(exportName, fallback: defaultExportName)
    }

    // MARK: - Frame preview

    /// Recomputes the planned frame times using the *same* function the exporter
    /// uses, so the preview and the export can never disagree.
    private func recomputePlannedTimes() {
        let times: [Double] = duration > 0
            ? FrameExporter.frameTimes(start: selectionStart, end: selectionEnd, settings: settings)
            : []

        // Settings that don't affect timing (format, scale, output) shouldn't
        // discard the user's hand-picked exclusions.
        guard times != plannedTimes else { return }

        plannedTimes = times
        excludedFrameIDs.removeAll()   // indices no longer refer to the same frames
        schedulePreviewRefresh()
    }

    func togglePreview() {
        isPreviewVisible.toggle()
        if isPreviewVisible {
            schedulePreviewRefresh()
        } else {
            previewTask?.cancel()
            previewTask = nil
            previewFrames = []
            isGeneratingPreview = false
        }
    }

    func toggleExclusion(_ id: Int) {
        if excludedFrameIDs.contains(id) {
            excludedFrameIDs.remove(id)
        } else {
            excludedFrameIDs.insert(id)
        }
    }

    func includeAllFrames() { excludedFrameIDs.removeAll() }

    /// Rebuilds the preview grid: seeds placeholder tiles immediately (so the
    /// layout and timestamps appear instantly), then renders thumbnails in the
    /// background after a short debounce.
    private func schedulePreviewRefresh() {
        previewTask?.cancel()
        previewTask = nil

        guard isPreviewVisible else {
            previewFrames = []
            isGeneratingPreview = false
            return
        }

        let times = Array(plannedTimes.prefix(Self.maxPreviewFrames))
        previewFrames = times.enumerated().map { PreviewFrame(id: $0.offset, time: $0.element, image: nil) }

        guard let asset, !times.isEmpty else {
            isGeneratingPreview = false
            return
        }

        isGeneratingPreview = true
        let clipDuration = duration
        previewTask = Task {
            // Debounce: dragging a slider shouldn't kick off a render per tick.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self.renderPreview(asset: asset, times: times, clipDuration: clipDuration)
        }
    }

    private func renderPreview(asset: AVAsset, times: [Double], clipDuration: Double) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // Match the exporter's frame accuracy so the preview isn't a near-miss.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let maxSeconds = clipDuration > 0 ? clipDuration - (1.0 / 600.0) : .greatestFiniteMagnitude

        for (index, seconds) in times.enumerated() {
            if Task.isCancelled { break }
            let clamped = max(0, min(seconds, maxSeconds))
            let time = CMTime(seconds: clamped, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { continue }
            let image = NSImage(cgImage: result.image, size: .zero)

            await MainActor.run {
                // Drop the result if the plan changed while this was rendering.
                guard index < self.previewFrames.count,
                      self.previewFrames[index].time == seconds else { return }
                self.previewFrames[index].image = image
            }
        }

        await MainActor.run {
            if !Task.isCancelled { self.isGeneratingPreview = false }
        }
    }

    // MARK: - Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            guard let self, let url else { return }
            DispatchQueue.main.async { self.load(url: url) }
        }
        return true
    }

    func load(url: URL) {
        isLoading = true
        errorMessage = nil
        let token = UUID()
        loadToken = token

        Task {
            do {
                let meta = try await VideoLoader.loadMetadata(url: url)
                await MainActor.run {
                    guard self.loadToken == token else { return }
                    self.apply(meta: meta, url: url)
                }
                await VideoLoader.generateThumbnails(asset: meta.asset, duration: meta.duration, count: 16) { image in
                    DispatchQueue.main.async {
                        guard self.loadToken == token else { return }
                        self.thumbnails.append(image)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.loadToken == token else { return }
                    self.isLoading = false
                    self.errorMessage = self.friendlyMessage(for: url, error: error)
                }
            }
        }
    }

    private func apply(meta: VideoLoader.Metadata, url: URL) {
        previewTask?.cancel()
        previewTask = nil
        asset = meta.asset
        videoURL = url
        videoSize = meta.displaySize
        duration = meta.duration
        selectionStart = 0
        selectionEnd = meta.duration
        currentTime = 0
        // Clear the typed name so the field re-derives from the new video.
        exportName = ""
        thumbnails = []
        previewFrames = []
        excludedFrameIDs = []
        isGeneratingPreview = false
        isLoading = false
        player.replaceCurrentItem(with: AVPlayerItem(asset: meta.asset))
        player.seek(to: .zero)
        // `duration` just changed, so the planned frame list must be rebuilt.
        recomputePlannedTimes()
    }

    private func friendlyMessage(for url: URL, error: Error) -> String {
        if url.pathExtension.lowercased() == "webm" {
            return "macOS can't read .webm files. Convert it to .mp4 or .mov first (e.g. with ffmpeg or an online converter), then open it here."
        }
        return error.localizedDescription
    }

    // MARK: - Playback

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(duration, seconds))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    // MARK: - Selection

    func setInToPlayhead() { selectionStart = min(currentTime, selectionEnd) }
    func setOutToPlayhead() { selectionEnd = max(currentTime, selectionStart) }
    func resetSelection() {
        selectionStart = 0
        selectionEnd = duration
    }

    // MARK: - Export

    func export() {
        guard let asset, duration > 0, !isExporting else { return }

        // Exactly what the preview showed, minus anything the user excluded.
        let times = exportTimes
        guard !times.isEmpty else {
            errorMessage = "Every frame is excluded — include at least one frame to export."
            return
        }

        let name = resolvedExportName
        let fileManager = FileManager.default
        let destination: URL
        // Only output this export created may be deleted if it fails part-way —
        // never a folder or archive that was already sitting there.
        let cleanUpOnFailure: Bool

        if settings.outputMode == .zip {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            // Prefilled from the Name field; whatever the user types in the save
            // dialog still wins.
            panel.nameFieldStringValue = "\(name).zip"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
            // The panel already asked before replacing an existing archive, so
            // that file is the user's to lose — but only to a finished export.
            cleanUpOnFailure = !fileManager.fileExists(atPath: url.path)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose Folder"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            // Always a folder that doesn't exist yet, so frames are never mixed
            // into someone else's folder and cleanup can't delete their files.
            destination = ExportNaming.uniqueFolderURL(in: dir, name: name)
            cleanUpOnFailure = true
        }

        isExporting = true
        exportProgress = 0

        let request = FrameExporter.Request(
            asset: asset,
            times: times,
            duration: duration,
            sourceSize: videoSize,
            settings: settings,
            destination: destination
        )

        exportTask = Task {
            do {
                try await FrameExporter.export(request) { value in
                    DispatchQueue.main.async { self.exportProgress = value }
                }
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 1
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch is CancellationError {
                if cleanUpOnFailure { try? fileManager.removeItem(at: destination) }
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 0
                }
            } catch {
                if cleanUpOnFailure { try? fileManager.removeItem(at: destination) }
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 0
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    // MARK: - Time observation

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite { self.currentTime = seconds }
        }
    }
}
