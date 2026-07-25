import SwiftUI
import AppKit

/// A contact-sheet grid of the frames that will be exported. Click a tile to
/// include/exclude it; click the locate button to jump the playhead there.
struct FramePreviewView: View {
    @EnvironmentObject var model: EditorModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    /// Tiles match the video's shape, so vertical clips don't sit in letterboxed boxes.
    private var tileAspect: CGFloat {
        let size = model.videoSize
        guard size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if model.previewFrames.isEmpty {
                Spacer()
                Text("No frames to preview.")
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.previewFrames) { frame in
                            FrameTile(
                                frame: frame,
                                aspect: tileAspect,
                                isExcluded: model.excludedFrameIDs.contains(frame.id),
                                onToggle: { model.toggleExclusion(frame.id) },
                                onLocate: { model.seek(to: frame.time) }
                            )
                        }
                    }
                    .padding(16)

                    if model.previewIsTruncated {
                        Text("Previewing the first \(EditorModel.maxPreviewFrames) of \(model.plannedFrameCount) frames — the rest are still exported, but can't be excluded individually here.")
                            .font(.caption)
                            .foregroundColor(Theme.warning)
                            .padding(.bottom, 16)
                            .padding(.horizontal, 16)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Frame preview")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)

            if model.isGeneratingPreview {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            Spacer()

            Text("\(model.includedFrameCount) of \(model.plannedFrameCount) selected")
                .font(.callout)
                .foregroundColor(model.excludedFrameIDs.isEmpty ? Theme.textSecondary : Theme.accent)
                .monospacedDigit()

            if !model.excludedFrameIDs.isEmpty {
                Button("Include All") { model.includeAllFrames() }
                    .controlSize(.small)
            }

            Button("Done") { model.togglePreview() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }
}

/// A single preview thumbnail with its index, timestamp and include state.
private struct FrameTile: View {
    let frame: PreviewFrame
    let aspect: CGFloat
    let isExcluded: Bool
    let onToggle: () -> Void
    let onLocate: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // The aspect constraint lives on the ZStack (not a child) so a
            // resizable image can't drive the cell's height.
            ZStack {
                Theme.panelElevated

                if let image = frame.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }

                if isExcluded {
                    Color.black.opacity(0.62)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isExcluded ? Color.clear : Theme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            )
            // Layered last so the button reliably wins the click over the tile.
            .overlay(alignment: .topLeading) {
                Button(action: onLocate) {
                    Image(systemName: "scope")
                        .font(.system(size: 10, weight: .bold))
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Jump the playhead to this frame")
            }

            HStack(spacing: 6) {
                Text("\(frame.id + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.textSecondary)
                Text(formatTimecode(frame.time))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(isExcluded ? Theme.textSecondary : Theme.textPrimary)
            }
        }
        .opacity(isExcluded ? 0.65 : 1)
        .help(isExcluded ? "Excluded — click to include" : "Click to exclude from the export")
    }
}
