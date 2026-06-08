import SwiftUI
import AVFoundation
import AppKit

/// Video preview (no built-in controls) plus a compact transport bar. Scrubbing
/// lives in the timeline below, so the preview stays clean.
struct PlayerView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            PlayerLayerView(player: model.player)
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            TransportBar()
                .padding(.horizontal, 16)
        }
    }
}

private struct TransportBar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Button(action: { model.togglePlayPause() }) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textPrimary)
            .background(Circle().fill(Theme.panelElevated))

            Text(formatTimecode(model.currentTime))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
            Text("/")
                .foregroundColor(Theme.textSecondary)
            Text(formatTimecode(model.duration))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(Theme.textSecondary)

            Spacer()
        }
    }
}

/// Hosts an `AVPlayerLayer` so the preview shows no system playback controls.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Assign the layer *before* setting wantsLayer so the view becomes
        // layer-hosting (we own the layer) rather than layer-backed.
        let base = CALayer()
        base.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        base.addSublayer(playerLayer)
        layer = base
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
