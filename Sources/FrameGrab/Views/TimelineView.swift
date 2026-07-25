import SwiftUI
import AppKit

/// Filmstrip timeline with a draggable in/out selection region, a playhead, and
/// quick "set in/out" controls.
struct TimelineView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            toolbar

            GeometryReader { geo in
                TimelineTrack(width: geo.size.width)
            }
            .frame(height: 76)
        }
        .padding(14)
        .background(Theme.panel)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label(formatTimecode(model.selectionStart), systemImage: "arrow.right.to.line")
                .foregroundColor(Theme.textPrimary)
            Label(formatTimecode(model.selectionEnd), systemImage: "arrow.left.to.line")
                .foregroundColor(Theme.textPrimary)
            Text("(\(String(format: "%.2f", model.selectionDuration))s)")
                .foregroundColor(Theme.textSecondary)

            Spacer()

            Button("Set In") { model.setInToPlayhead() }
            Button("Set Out") { model.setOutToPlayhead() }
            Button("Reset") { model.resetSelection() }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct TimelineTrack: View {
    @EnvironmentObject var model: EditorModel
    let width: CGFloat

    private let handleWidth: CGFloat = 22

    private func x(for time: Double) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(time / model.duration) * width
    }

    private func time(for x: CGFloat) -> Double {
        guard width > 0, model.duration > 0 else { return 0 }
        return Double(min(max(0, x), width) / width) * model.duration
    }

    var body: some View {
        let startX = x(for: model.selectionStart)
        let endX = x(for: model.selectionEnd)

        ZStack(alignment: .leading) {
            // Filmstrip background.
            FilmstripView(thumbnails: model.thumbnails)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)

            // Transparent layer that turns taps/drags into seeks.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { value in model.seek(to: time(for: value.location.x)) }
                )

            // Dim the regions outside the selection.
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .frame(width: max(0, startX))
                .allowsHitTesting(false)
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .frame(width: max(0, width - endX))
                .offset(x: endX)
                .allowsHitTesting(false)

            // Selection outline.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: max(0, endX - startX))
                .offset(x: startX)
                .allowsHitTesting(false)

            // Sample ticks: exactly where each exported frame is taken from.
            FrameTicksView()
                .allowsHitTesting(false)

            // Playhead.
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
                .offset(x: min(max(0, x(for: model.currentTime)), width))
                .shadow(color: .black.opacity(0.6), radius: 1)
                .allowsHitTesting(false)

            handle()
                .offset(x: startX - handleWidth / 2)
                .gesture(handleDrag(isStart: true))
            handle()
                .offset(x: endX - handleWidth / 2)
                .gesture(handleDrag(isStart: false))
        }
        .frame(width: width)
        .coordinateSpace(name: "timeline")
    }

    private func handle() -> some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.accent)
                .frame(width: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 2, height: 18)
                )
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func handleDrag(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                let t = time(for: value.location.x)
                if isStart {
                    model.selectionStart = max(0, min(t, model.selectionEnd))
                } else {
                    model.selectionEnd = min(model.duration, max(t, model.selectionStart))
                }
                model.seek(to: t)
            }
    }
}

/// Draws a tick at every timestamp the exporter will sample, so the spacing of
/// the frame set is visible at a glance (dense for high FPS, sparse for a low
/// count). Excluded frames are drawn in red.
private struct FrameTicksView: View {
    @EnvironmentObject var model: EditorModel

    /// Beyond this the ticks merge into a smear — subsample so drawing stays cheap.
    private let maxTicks = 400

    var body: some View {
        Canvas { context, size in
            guard model.duration > 0, !model.plannedTimes.isEmpty else { return }

            let bandHeight: CGFloat = 14
            let band = CGRect(x: 0, y: size.height - bandHeight, width: size.width, height: bandHeight)
            context.fill(Path(band), with: .color(.black.opacity(0.55)))

            let count = model.plannedTimes.count
            let step = max(1, count / maxTicks)

            for index in Swift.stride(from: 0, to: count, by: step) {
                let x = CGFloat(model.plannedTimes[index] / model.duration) * size.width
                let excluded = model.excludedFrameIDs.contains(index)
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - 2))
                path.addLine(to: CGPoint(x: x, y: size.height - bandHeight + 2))
                context.stroke(
                    path,
                    with: .color(excluded ? Color.red.opacity(0.9) : Color.white.opacity(0.95)),
                    lineWidth: 1.5
                )
            }
        }
    }
}

/// Renders the thumbnails evenly across the available width.
private struct FilmstripView: View {
    let thumbnails: [NSImage]

    var body: some View {
        GeometryReader { geo in
            if thumbnails.isEmpty {
                Theme.panelElevated
            } else {
                HStack(spacing: 0) {
                    ForEach(thumbnails.indices, id: \.self) { index in
                        Image(nsImage: thumbnails[index])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width / CGFloat(thumbnails.count), height: geo.size.height)
                            .clipped()
                    }
                }
            }
        }
    }
}
