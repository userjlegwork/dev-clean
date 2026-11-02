import AppKit
import DevCleanCore
import SwiftUI

@main
struct DevCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement for the bundled app; this covers `swift run` too.
        NSApp.setActivationPolicy(.accessory)
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
