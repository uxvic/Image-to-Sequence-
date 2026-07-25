import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: EditorModel
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Theme.background
                if model.videoURL == nil {
                    EmptyStateView(isTargeted: isDropTargeted)
                } else {
                    VStack(spacing: 0) {
                        // The preview grid takes over the player area so the
                        // timeline (and its sample ticks) stay visible below.
                        if model.isPreviewVisible {
                            FramePreviewView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            PlayerView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        TimelineView()
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                model.handleDrop(providers: providers)
            }

            Divider().overlay(Theme.stroke)

            ExportPanelView()
                .frame(width: 320)
                .background(Theme.panel)
        }
        .background(Theme.background)
        .alert(
            "Couldn't load that video",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Drop target + open button shown before a video is loaded.
private struct EmptyStateView: View {
    @EnvironmentObject var model: EditorModel
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(Theme.accent)

            VStack(spacing: 6) {
                Text("Drop a video here")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Select a region, then export it as an image sequence")
                    .font(.callout)
                    .foregroundColor(Theme.textSecondary)
            }

            Button("Open Video…") { model.presentOpenPanel() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)

            Text("MP4 · MOV · M4V")
                .font(.caption)
                .foregroundColor(Theme.textSecondary.opacity(0.8))
        }
        .padding(48)
        .frame(maxWidth: 460)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .foregroundColor(isTargeted ? Theme.accent : Theme.stroke)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}
