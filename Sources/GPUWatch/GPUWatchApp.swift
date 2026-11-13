import AppKit
import SwiftUI

@main
struct GPUWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage("appearance") private var appearance = Appearance.system

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("GPU Watch", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 560)
                .task { model.start() }
        }
        .defaultSize(width: 1120, height: 800)
        // Otherwise a crash or reboot can reopen on the last page instead of ZheServer.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refreshCurrentPage() }
                    .keyboardShortcut("r")
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                Divider()
            }
        }
    }
}

/// Owns the model because the `@State` macro's plugin ships with Xcode, not the Command
/// Line Tools. The delegate lives exactly as long as the app, which is what's needed here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
