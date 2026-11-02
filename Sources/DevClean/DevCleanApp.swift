import AppKit
import DevCleanCore
import SwiftUI
import UserNotifications

@main
struct DevCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: appDelegate.monitor, storage: appDelegate.storage, automation: appDelegate.automation)
        } label: {
            MenuBarLabel(monitor: appDelegate.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the shared models so the menu-bar popover and the standalone window show the same state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let monitor = SystemMonitor()
    let storage = StorageModel()
    let automation = Automation()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement for the bundled app; this covers `swift run` too.
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        monitor.onRefresh = { [unowned self] in automation.check(monitor: monitor, storage: storage) }
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
                rootView: DashboardView(monitor: monitor, storage: storage, automation: automation)))
            window.title = "DevClean"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // While the window is open, act like a normal app (Dock icon, ⌘Tab) so it can't get lost behind others.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Clicking a notification opens the window on the tab it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let tab = response.notification.request.content.userInfo["tab"] as? String
        await MainActor.run {
            if let tab { UserDefaults.standard.set(tab, forKey: "dashboardTab") }
            showWindow()
        }
    }

    /// Show banners even while DevClean is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
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
