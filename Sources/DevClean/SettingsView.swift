import AppKit
import DevCleanCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let monitor: SystemMonitor
    let storage: StorageModel
    @Bindable var automation: Automation

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            notifications
            Divider()
            autoClean
            Divider()
            general
        }
        .task { if automation.notificationsEnabled { await automation.requestAuthorization() } }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications").font(.subheadline.weight(.semibold))
            Toggle("Tell me when disk, memory or swap need attention", isOn: $automation.notificationsEnabled)
                .toggleStyle(.checkbox)
            Text("Warnings at most once a day each; critical problems every 6 hours, or right away when they get worse.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if automation.notificationsEnabled && automation.notificationsDenied {
                HStack {
                    Label("Notifications are off for DevClean in System Settings", systemImage: "bell.slash")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open") { automation.openNotificationSettings() }.controlSize(.small)
                }
                if let error = automation.notificationError {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var autoClean: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Automatic cleanup").font(.subheadline.weight(.semibold))
            Picker("", selection: $automation.autoCleanMode) {
                Text("Off").tag(AutoCleanMode.off)
                Text("When free space is under \(Format.disk(automation.thresholds.minFreeDisk))").tag(AutoCleanMode.whenLow)
                Text("Weekly").tag(AutoCleanMode.weekly)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("Clears only caches that rebuild themselves: \(autoTargetNames). Anything in use is skipped, and uv waits until no uv process is running. Worktrees, large files and simulators stay manual. At most once a day.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                if automation.isAutoCleaning {
                    ProgressView().controlSize(.small)
                    Text("Cleaning…").font(.caption)
                } else if let last = automation.lastAutoClean {
                    Text("Last run \(Format.age(since: last)) ago" + (automation.lastAutoCleanResult.map { ": \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Run now") { Task { await automation.runAutoClean(monitor: monitor, storage: storage) } }
                    .controlSize(.small)
                    .disabled(automation.isAutoCleaning || storage.isRunning)
            }
        }
    }

    private var autoTargetNames: String {
        let names = AutoCleanPolicy.targets(from: storage.targets).map(\.name)
        return names.isEmpty ? "none found on this Mac" : names.joined(separator: ", ")
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("General").font(.subheadline.weight(.semibold))
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
            Button("Open cleanup log") { NSWorkspace.shared.open(storage.log.url) }
                .controlSize(.small)
                .disabled(!FileManager.default.fileExists(atPath: storage.log.url.path))
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Needs the bundled app (scripts/bundle.sh): \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
