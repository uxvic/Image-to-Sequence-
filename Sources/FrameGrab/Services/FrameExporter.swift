import AVFoundation
import CoreMedia
import AppKit

/// Extracts still frames from a video region and writes them either as loose
/// files in a folder or bundled into a `.zip`. Frame-accurate, async, and
/// cancellable.
enum FrameExporter {

    struct Request {
        let asset: AVAsset
        /// The exact timestamps to sample, in order. Precomputed by the caller
        /// (via `frameTimes`) so the on-screen preview and the written files can
        /// never disagree, and so excluded frames are simply absent here.
        let times: [Double]
        let duration: Double         // full clip duration, used to clamp the last sample
        let sourceSize: CGSize       // display size, used to avoid upscaling
        let settings: ExportSettings
        /// A `.zip` file URL when `settings.outputMode == .zip`, otherwise a
        /// (not-yet-existing) folder URL to create and fill with frames.
        let destination: URL
    }

    enum ExportError: LocalizedError {
        case noFrames
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noFrames: return "There are no frames to export for the selected range."
            case .encodingFailed: return "A frame couldn't be encoded as an image."
            }
        }
    }

    /// The exact timestamps (seconds) that will be sampled for the given range
    /// and settings. Used both by the exporter and by the live estimate in the UI.
    static func frameTimes(start: Double, end: Double, settings: ExportSettings) -> [Double] {
        let lo = min(start, end)
        let hi = max(start, end)
        let span = max(0, hi - lo)

        switch settings.mode {
        case .fps:
            let fps = max(0.01, settings.fps)
            let step = 1.0 / fps
            var times: [Double] = []
            var t = lo
            while t <= hi + 1e-6 {
                times.append(min(t, hi))
                t += step
                if times.count >= 10_000 { break } // safety cap
            }
            return times.isEmpty ? [lo] : times

        case .count:
            let n = max(1, settings.frameCount)
            if n == 1 { return [lo + span / 2] }
            return (0..<n).map { i in lo + span * Double(i) / Double(n - 1) }
        }
    }

    /// Runs the export. `progress` is called with a value in `0...1` after each
    /// frame is written (on an arbitrary thread — marshal to the main thread in
    /// the handler if updating UI).
    static func export(_ request: Request, progress: @escaping (Double) -> Void) async throws {
        let times = request.times
        guard !times.isEmpty else { throw ExportError.noFrames }

        let isZip = request.settings.outputMode == .zip
        let fileManager = FileManager.default

        // Directory we actually write the frames into.
        let writeDir: URL
        if isZip {
            // Name the temp folder after the zip so the archive's top-level
            // folder reads nicely once unzipped.
            let stem = request.destination.deletingPathExtension().lastPathComponent
            writeDir = fileManager.temporaryDirectory
                .appendingPathComponent("FrameGrab-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(stem, isDirectory: true)
        } else {
            writeDir = request.destination
        }
        try fileManager.createDirectory(at: writeDir, withIntermediateDirectories: true)

        // For zip exports, always clean up the temp staging area afterwards.
        defer {
            if isZip {
                try? fileManager.removeItem(at: writeDir.deletingLastPathComponent())
            }
        }

        let generator = AVAssetImageGenerator(asset: request.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxWidth = request.settings.scale.maxWidth,
           request.sourceSize.width > 0,
           CGFloat(maxWidth) < request.sourceSize.width {
            let scale = CGFloat(maxWidth) / request.sourceSize.width
            let targetHeight = (request.sourceSize.height * scale).rounded()
            generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: targetHeight)
        }

        let total = times.count
        let pad = max(4, String(total).count)
        let ext = request.settings.format.fileExtension

        // Asking for a frame at exactly the clip duration can fail with zero
        // tolerance — there's no sample at/after the end. Keep the last request
        // a hair inside the clip.
        let maxSeconds = request.duration > 0 ? request.duration - (1.0 / 600.0) : .greatestFiniteMagnitude

        for (index, seconds) in times.enumerated() {
            try Task.checkCancellation()

            let clamped = max(0, min(seconds, maxSeconds))
            let time = CMTime(seconds: clamped, preferredTimescale: 600)
            let result = try await generator.image(at: time)
            let data = try encode(cgImage: result.image, settings: request.settings)

            let name = "frame_" + String(format: "%0\(pad)d", index + 1) + "." + ext
            try data.write(to: writeDir.appendingPathComponent(name))

            progress(Double(index + 1) / Double(total))
        }

        if isZip {
            try zipDirectory(writeDir, to: request.destination)
        }
    }

    // MARK: - Encoding

    private static func encode(cgImage: CGImage, settings: ExportSettings) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let fileType: NSBitmapImageRep.FileType
        let properties: [NSBitmapImageRep.PropertyKey: Any]

        switch settings.format {
        case .png:
            fileType = .png
            properties = [:]
        case .jpeg:
            fileType = .jpeg
            properties = [.compressionFactor: settings.jpegQuality]
        }

        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    // MARK: - Zipping (pure Foundation, no external tooling)

    private static func zipDirectory(_ directory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var innerError: Error?

        // `.forUploading` hands back a zipped copy of the directory in a temp
        // location that is valid only for the duration of the accessor block.
        coordinator.coordinate(readingItemAt: directory, options: [.forUploading], error: &coordinationError) { zippedURL in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: zippedURL, to: destination)
            } catch {
                innerError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let innerError { throw innerError }
    }
}
