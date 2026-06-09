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
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0

    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var exportTask: Task<Void, Never>?
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
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    // MARK: - Derived values

    var selectionDuration: Double { max(0, selectionEnd - selectionStart) }

    /// Cheap estimate that mirrors `FrameExporter.frameTimes(...).count` without
    /// building the array on every UI update.
    var estimatedFrameCount: Int {
        switch settings.mode {
        case .count:
            return max(1, settings.frameCount)
        case .fps:
            return max(1, Int(floor(selectionDuration * max(0.01, settings.fps))) + 1)
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
        asset = meta.asset
        videoURL = url
        videoSize = meta.displaySize
        duration = meta.duration
        selectionStart = 0
        selectionEnd = meta.duration
        currentTime = 0
        thumbnails = []
        isLoading = false
        player.replaceCurrentItem(with: AVPlayerItem(asset: meta.asset))
        player.seek(to: .zero)
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

        let stem = videoURL?.deletingPathExtension().lastPathComponent ?? "frames"
        let destination: URL

        if settings.outputMode == .zip {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = "\(stem)_frames.zip"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose Folder"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            destination = dir.appendingPathComponent("\(stem)_frames", isDirectory: true)
        }

        isExporting = true
        exportProgress = 0

        let request = FrameExporter.Request(
            asset: asset,
            start: selectionStart,
            end: selectionEnd,
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
                try? FileManager.default.removeItem(at: destination)
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 0
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
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
