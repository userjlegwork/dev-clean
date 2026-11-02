import AppKit
import DevCleanCore
import SwiftUI

@main
struct DevCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: appDelegate.monitor, storage: appDelegate.storage)
        } label: {
            MenuBarLabel(monitor: appDelegate.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the shared models so the menu-bar popover and the standalone window show the same state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SystemMonitor()
    let storage = StorageModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement for the bundled app; this covers `swift run` too.
        NSApp.setActivationPolicy(.accessory)
        // Opened by hand (Finder, Spotlight, `open`): show a window too, since the menu-bar
        // icon is easy to miss or can be hidden behind the notch. Stay quiet as a login item.
        if !launchedAsLoginItem() { showWindow() }
    }

    /// Opening the app again while it's running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: DashboardView(monitor: monitor, storage: storage)))
            window.title = "DevClean"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// Icon reflects the worst current insight; text is free disk space.
struct MenuBarLabel: View {
    let monitor: SystemMonitor

    var body: some View {
        let severity = Insights.overall(monitor.insights)
        HStack(spacing: 4) {
            Image(systemName: severity.symbolName)
            if let disk = monitor.system?.disk {
                Text(Format.disk(disk.free))
            }
        }
    }
}

extension Severity {
    var symbolName: String {
        switch self {
        case .ok: "gauge.with.dots.needle.33percent"
        case .info: "gauge.with.dots.needle.50percent"
        case .warning: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
