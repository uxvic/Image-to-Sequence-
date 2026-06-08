import AVFoundation
import CoreMedia
import AppKit

/// Loads metadata and timeline thumbnails for a video file using AVFoundation's
/// modern async loading APIs (macOS 13+).
enum VideoLoader {

    struct Metadata {
        let asset: AVURLAsset
        let duration: Double      // seconds
        let displaySize: CGSize   // pixel size after applying the track transform
    }

    enum LoadError: LocalizedError {
        case invalidDuration
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .invalidDuration:
                return "The file doesn't have a readable duration."
            case .noVideoTrack:
                return "The file doesn't contain a video track."
            }
        }
    }

    /// Reads duration and display dimensions. Throws if the asset is unreadable
    /// (e.g. an unsupported container such as `.webm`).
    static func loadMetadata(url: URL) async throws -> Metadata {
        let asset = AVURLAsset(url: url)

        let durationTime = try await asset.load(.duration)
        let seconds = durationTime.seconds
        guard seconds.isFinite, seconds > 0 else { throw LoadError.invalidDuration }

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw LoadError.noVideoTrack }

        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let transformed = naturalSize.applying(transform)
        let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))

        return Metadata(asset: asset, duration: seconds, displaySize: displaySize)
    }

    /// Generates evenly-spaced thumbnails across the whole clip. `onEach` is
    /// called (on an arbitrary thread) as each thumbnail becomes available so
    /// the UI can fill the filmstrip progressively.
    static func generateThumbnails(
        asset: AVAsset,
        duration: Double,
        count: Int,
        onEach: @escaping (NSImage) -> Void
    ) async {
        guard duration > 0, count > 0 else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 200)
        // Thumbnails don't need frame-accuracy; loosen tolerance for speed.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        for index in 0..<count {
            let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                let image = NSImage(cgImage: result.image, size: .zero)
                onEach(image)
            }
        }
    }
}
