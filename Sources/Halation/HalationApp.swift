import SwiftUI
import AppKit

@main
struct HalationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var model = ViewerModel.shared

    var body: some Scene {
        Window("Halation", id: "viewer") {
            ViewerView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 400)
        }
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ViewerModel.shared.applyAppearance()

        // Plain-key shortcuts (arrows, space, letters) are handled by a local
        // monitor so they work no matter which view has focus.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if ViewerModel.shared.handleKey(event) { return nil }
            return event
        }

        let args = CommandLine.arguments.dropFirst()
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !args.isEmpty {
            ViewerModel.shared.open(Array(args))
        }
        NSApp.activate(ignoringOtherApps: true)

        // Headless smoke test: HALATION_TEST_APPEARANCE=1 cycles appearance
        // modes after launch and reports whether the app survived.
        if ProcessInfo.processInfo.environment["HALATION_TEST_APPEARANCE"] != nil {
            let model = ViewerModel.shared
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.appearance = .light }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { model.appearance = .dark }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { model.appearance = .system }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let visible = NSApp.windows.filter(\.isVisible).count
                print("APPEARANCE_TEST_DONE visibleWindows=\(visible)")
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ViewerModel.shared.open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Appearance switches can momentarily close/recreate the viewer window;
        // don't mistake that churn for the user quitting the app.
        Date().timeIntervalSince(ViewerModel.shared.lastAppearanceChange) > 3
    }
}
