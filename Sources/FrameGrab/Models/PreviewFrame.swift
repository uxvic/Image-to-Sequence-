import AppKit
import Foundation

/// One frame that the exporter will sample: its position in the output sequence,
/// its timestamp, and (once rendered) a small preview image.
///
/// The list of these is derived from the very same
/// `FrameExporter.frameTimes(start:end:settings:)` the exporter uses, so what the
/// preview shows is exactly what gets written.
struct PreviewFrame: Identifiable {
    /// 0-based index in the planned export sequence.
    let id: Int
    /// Timestamp in seconds.
    let time: Double
    /// Rendered thumbnail; `nil` until the async render reaches this frame.
    var image: NSImage?
}
