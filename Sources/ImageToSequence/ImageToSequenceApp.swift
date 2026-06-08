import SwiftUI
import AppKit

@main
struct ImageToSequenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        WindowGroup("Image to Sequence") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .commands {
            // Replace "New" with "Open Video…" (⌘O).
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// Ensures the app activates and shows a window/menu bar even when launched as a
/// bare SwiftPM executable (outside a `.app` bundle, e.g. `swift run`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
