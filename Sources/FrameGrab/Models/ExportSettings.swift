import Foundation

/// How the frames inside the selected region are chosen.
enum SelectionMode: String, CaseIterable, Identifiable {
    /// Extract frames at a fixed rate (frames per second).
    case fps = "FPS"
    /// Extract an exact number of evenly-spaced frames.
    case count = "Count"

    var id: String { rawValue }
}

/// Output image format for each exported frame.
enum ImageFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

/// Where the exported frames are written.
enum OutputMode: String, CaseIterable, Identifiable {
    /// Bundle every frame into a single `.zip`.
    case zip = "ZIP"
    /// Write loose image files into a chosen folder.
    case folder = "Folder"

    var id: String { rawValue }
}

/// Optional downscaling applied to each frame. Useful for keeping LLM inputs
/// small — full-resolution UI screen recordings are rarely needed.
enum ScaleOption: String, CaseIterable, Identifiable {
    case original = "Original"
    case w1280 = "≤ 1280px"
    case w960 = "≤ 960px"
    case w640 = "≤ 640px"

    var id: String { rawValue }

    /// Maximum width in pixels, or `nil` to keep the source resolution.
    var maxWidth: Int? {
        switch self {
        case .original: return nil
        case .w1280: return 1280
        case .w960: return 960
        case .w640: return 640
        }
    }
}

/// All user-tunable export options. A plain value type so it is trivial to copy
/// into a background export request.
struct ExportSettings: Equatable {
    var mode: SelectionMode = .count
    var fps: Double = 2
    var frameCount: Int = 12
    var format: ImageFormat = .png
    var jpegQuality: Double = 0.9
    var scale: ScaleOption = .original
    var outputMode: OutputMode = .zip
}
