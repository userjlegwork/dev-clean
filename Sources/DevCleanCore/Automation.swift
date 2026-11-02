import Foundation

/// When an insight was last notified, so the same problem doesn't notify every poll.
public struct NotificationRecord: Codable, Sendable, Equatable {
    public var severity: Int
    public var sent: Date

    public init(severity: Severity, sent: Date) {
        self.severity = severity.rawValue
        self.sent = sent
    }
}

public struct NotificationPolicy: Sendable {
    /// How long before the same insight notifies again at the same severity.
    public var warningCooldown: TimeInterval = 24 * 3_600
    public var criticalCooldown: TimeInterval = 6 * 3_600

    public init() {}

    /// Insights to notify now, and the updated history. Only warnings and criticals notify; info never does.
    /// A worse severity notifies right away. Records outlive the insight itself, so a problem that flaps
    /// (pressure going elevated, normal, elevated) still notifies once per cooldown.
    public func decide(_ insights: [Insight], history: [String: NotificationRecord],
                       now: Date = Date()) -> (send: [Insight], history: [String: NotificationRecord]) {
        var history = history.filter { now.timeIntervalSince($0.value.sent) < max(warningCooldown, criticalCooldown) }
        var send: [Insight] = []
        for insight in insights where insight.severity >= .warning {
            let cooldown = insight.severity == .critical ? criticalCooldown : warningCooldown
            if let record = history[insight.id], record.severity >= insight.severity.rawValue,
               now.timeIntervalSince(record.sent) < cooldown {
                continue
            }
            send.append(insight)
            history[insight.id] = NotificationRecord(severity: insight.severity, sent: now)
        }
        return (send, history)
    }
}

public enum AutoCleanMode: String, CaseIterable, Sendable {
    case off, whenLow, weekly
}

public enum AutoCleanPolicy {
    /// Caches that rebuild on their own and never hold work. Simulators, DerivedData (slow rebuilds),
    /// Playwright browsers, worktrees and large files stay manual.
    public static let targetIDs = ["npm", "pip", "homebrew", "bun", "pnpm", "uv"]
    public static let minimumGap: TimeInterval = 24 * 3_600
    public static let weeklyGap: TimeInterval = 7 * 24 * 3_600

    /// The automatic subset of the catalog. uv's clean uses --force (it otherwise waits on a lock forever),
    /// so unattended runs also wait until no uv process is running.
    public static func targets(from catalog: [CleanupTarget]) -> [CleanupTarget] {
        catalog.filter { targetIDs.contains($0.id) }.map { target in
            var target = target
            if target.id == "uv", !target.blockingProcesses.contains("uv") { target.blockingProcesses.append("uv") }
            return target
        }
    }

    public static func isDue(_ mode: AutoCleanMode, lastRun: Date?, now: Date = Date(),
                             diskFree: UInt64?, minFreeDisk: UInt64) -> Bool {
        let sinceLast = now.timeIntervalSince(lastRun ?? .distantPast)
        switch mode {
        case .off: return false
        case .whenLow: return sinceLast >= minimumGap && (diskFree.map { $0 < minFreeDisk } ?? false)
        case .weekly: return sinceLast >= weeklyGap
        }
    }
}
