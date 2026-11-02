import AppKit
import DevCleanCore
import Foundation
import Observation
import UserNotifications

/// Turns insights into notifications and runs the opt-in automatic cache cleanup.
@MainActor
@Observable
final class Automation {
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notifications)
            if notificationsEnabled { Task { await requestAuthorization() } }
        }
    }
    var autoCleanMode: AutoCleanMode {
        didSet {
            defaults.set(autoCleanMode.rawValue, forKey: Keys.autoCleanMode)
            // Weekly counts from when it was switched on, not from never.
            if autoCleanMode == .weekly, lastAutoClean == nil { lastAutoClean = Date() }
        }
    }
    private(set) var lastAutoClean: Date? {
        didSet { defaults.set(lastAutoClean, forKey: Keys.lastAutoClean) }
    }
    private(set) var lastAutoCleanResult: String? {
        didSet { defaults.set(lastAutoCleanResult, forKey: Keys.lastAutoCleanResult) }
    }
    /// Notifications are switched off for DevClean in System Settings.
    private(set) var notificationsDenied = false
    private(set) var notificationError: String?
    private(set) var isAutoCleaning = false

    let policy = NotificationPolicy()
    let thresholds = Thresholds()

    private let defaults = UserDefaults.standard
    private var history: [String: NotificationRecord]
    private var lastAutoCleanCheck: Date?
    /// UNUserNotificationCenter crashes outside an app bundle (`swift run`).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private enum Keys {
        static let notifications = "notificationsEnabled"
        static let autoCleanMode = "autoCleanMode"
        static let lastAutoClean = "lastAutoClean"
        static let lastAutoCleanResult = "lastAutoCleanResult"
        static let history = "notificationHistory"
    }

    init() {
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        autoCleanMode = AutoCleanMode(rawValue: defaults.string(forKey: Keys.autoCleanMode) ?? "") ?? .off
        lastAutoClean = defaults.object(forKey: Keys.lastAutoClean) as? Date
        lastAutoCleanResult = defaults.string(forKey: Keys.lastAutoCleanResult)
        history = (defaults.data(forKey: Keys.history))
            .flatMap { try? JSONDecoder().decode([String: NotificationRecord].self, from: $0) } ?? [:]
        if notificationsEnabled { Task { await requestAuthorization() } }
    }

    /// Called after each poll.
    func check(monitor: SystemMonitor, storage: StorageModel) {
        if notificationsEnabled, canNotify, !notificationsDenied { notify(monitor.insights) }

        // The schedule only needs checking every few minutes, not every poll.
        let now = Date()
        guard now.timeIntervalSince(lastAutoCleanCheck ?? .distantPast) >= 600 else { return }
        lastAutoCleanCheck = now
        if AutoCleanPolicy.isDue(autoCleanMode, lastRun: lastAutoClean, now: now,
                                 diskFree: monitor.system?.disk.free, minFreeDisk: thresholds.minFreeDisk) {
            Task { await runAutoClean(monitor: monitor, storage: storage) }
        }
    }

    func runAutoClean(monitor: SystemMonitor, storage: StorageModel) async {
        guard !isAutoCleaning, !storage.isRunning else { return }
        isAutoCleaning = true
        defer { isAutoCleaning = false }

        let targets = AutoCleanPolicy.targets(from: storage.targets)
        let running = RunningProcesses.current()
        // Skip what's blocked right now (Homebrew mid-install, uv running) instead of reporting failures.
        let runnable = targets.filter { CleanupRunner.plan($0, running: running).canRun }
        lastAutoClean = Date()
        guard let outcome = await storage.clean(runnable, automatic: true, diskFree: { monitor.liveDiskFree() }) else {
            lastAutoCleanResult = runnable.isEmpty ? "Nothing to clean: every cache was in use" : nil
            return
        }

        let skipped = targets.count - runnable.count
        var text = "Freed \(Format.disk(outcome.freed)) from \(runnable.map(\.name).joined(separator: ", "))."
        if skipped > 0 { text += " Skipped \(skipped) in use." }
        if outcome.failures > 0 { text += " \(outcome.failures) failed; see the log." }
        lastAutoCleanResult = text
        post(id: "auto-clean", title: "DevClean cleaned caches", body: text, tab: "storage")
        await monitor.refresh()
    }

    // MARK: - Notifications

    private func notify(_ insights: [Insight]) {
        let (send, history) = policy.decide(insights, history: history)
        guard history != self.history else { return }
        self.history = history
        defaults.set(try? JSONEncoder().encode(history), forKey: Keys.history)
        for insight in send {
            post(id: insight.id, title: insight.title, body: insight.detail, tab: Self.tab(for: insight.id))
        }
    }

    private func post(id: String, title: String, body: String, tab: String) {
        guard notificationsEnabled, canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["tab": tab]
        // Same identifier replaces an older notification about the same thing.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func tab(for insightID: String) -> String {
        switch insightID {
        case "disk": "storage"
        case "stale-servers": "devServers"
        default: "overview"
        }
    }

    func requestAuthorization() async {
        guard canNotify else { return }
        do {
            notificationsDenied = try await !UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationError = nil
        } catch {
            notificationsDenied = true
            notificationError = error.localizedDescription
        }
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}
