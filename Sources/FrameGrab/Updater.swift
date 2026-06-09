// Sparkle auto-update integration.
//
// The whole file is compiled only when Sparkle is linked (i.e. when building the
// Xcode project generated from project.yml). A plain `swift run` / `swift build`
// via Package.swift does not include Sparkle, so this file compiles to nothing
// and the app still runs — just without auto-update.

#if canImport(Sparkle)
import SwiftUI
import Combine
import Sparkle

/// Publishes whether the updater is currently able to check, so the menu item
/// can disable itself while a check is already in flight.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// A "Check for Updates…" menu command backed by Sparkle.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
#endif
