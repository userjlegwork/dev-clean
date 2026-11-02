import Foundation
import Testing
@testable import DevCleanCore

@Suite struct NotificationPolicyTests {
    private let policy = NotificationPolicy()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func insight(_ id: String, _ severity: Severity) -> Insight {
        Insight(id: id, severity: severity, title: id, detail: "")
    }

    @Test func infoNeverNotifies() {
        let result = policy.decide([insight("uptime", .info), insight("stale-servers", .info)], history: [:], now: start)
        #expect(result.send.isEmpty && result.history.isEmpty)
    }

    @Test func warningNotifiesOncePerDay() {
        var (send, history) = policy.decide([insight("swap", .warning)], history: [:], now: start)
        #expect(send.map(\.id) == ["swap"])
        (send, history) = policy.decide([insight("swap", .warning)], history: history, now: start + 23 * 3_600)
        #expect(send.isEmpty)
        (send, history) = policy.decide([insight("swap", .warning)], history: history, now: start + 24 * 3_600)
        #expect(send.map(\.id) == ["swap"])
    }

    @Test func escalationNotifiesImmediatelyAndCriticalRepeatsSooner() {
        var (send, history) = policy.decide([insight("disk", .warning)], history: [:], now: start)
        (send, history) = policy.decide([insight("disk", .critical)], history: history, now: start + 60)
        #expect(send.map(\.id) == ["disk"])
        (send, history) = policy.decide([insight("disk", .critical)], history: history, now: start + 5 * 3_600)
        #expect(send.isEmpty)
        (send, history) = policy.decide([insight("disk", .critical)], history: history, now: start + 60 + 6 * 3_600)
        #expect(send.map(\.id) == ["disk"])
        // Back down to a warning within the day: already told about something worse.
        (send, _) = policy.decide([insight("disk", .warning)], history: history, now: start + 7 * 3_600)
        #expect(send.isEmpty)
    }

    @Test func flappingInsightDoesNotRenotify() {
        var (_, history) = policy.decide([insight("pressure", .warning)], history: [:], now: start)
        history = policy.decide([], history: history, now: start + 600).history
        let (send, _) = policy.decide([insight("pressure", .warning)], history: history, now: start + 1_200)
        #expect(send.isEmpty)
    }

    @Test func oldRecordsAreDropped() {
        let (_, history) = policy.decide([insight("swap", .warning)], history: [:], now: start)
        #expect(policy.decide([], history: history, now: start + 25 * 3_600).history.isEmpty)
    }
}

@Suite struct AutoCleanPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let min: UInt64 = 20_000_000_000

    @Test func offNeverRuns() {
        #expect(!AutoCleanPolicy.isDue(.off, lastRun: nil, now: now, diskFree: 1, minFreeDisk: min))
    }

    @Test func whenLowNeedsLowDiskAndADayGap() {
        #expect(AutoCleanPolicy.isDue(.whenLow, lastRun: nil, now: now, diskFree: min - 1, minFreeDisk: min))
        #expect(!AutoCleanPolicy.isDue(.whenLow, lastRun: nil, now: now, diskFree: min, minFreeDisk: min))
        #expect(!AutoCleanPolicy.isDue(.whenLow, lastRun: nil, now: now, diskFree: nil, minFreeDisk: min))
        #expect(!AutoCleanPolicy.isDue(.whenLow, lastRun: now - 23 * 3_600, now: now, diskFree: 1, minFreeDisk: min))
        #expect(AutoCleanPolicy.isDue(.whenLow, lastRun: now - 24 * 3_600, now: now, diskFree: 1, minFreeDisk: min))
    }

    @Test func weeklyIgnoresDiskSpace() {
        #expect(!AutoCleanPolicy.isDue(.weekly, lastRun: now - 6 * 86_400, now: now, diskFree: 1, minFreeDisk: min))
        #expect(AutoCleanPolicy.isDue(.weekly, lastRun: now - 7 * 86_400, now: now, diskFree: 500 * min, minFreeDisk: min))
    }

    @Test func onlyRebuildableCachesAndUvWaitsForUv() {
        let catalog = CleanupCatalog.standard(home: "/Users/me", fileExists: { _ in true })
        let targets = AutoCleanPolicy.targets(from: catalog)
        #expect(Set(targets.map(\.id)) == Set(AutoCleanPolicy.targetIDs))
        #expect(targets.first { $0.id == "uv" }?.blockingProcesses.contains("uv") == true)
        #expect(!targets.contains { $0.id.hasPrefix("simulator") || $0.id == "derived-data" || $0.id == "playwright" })
    }
}
