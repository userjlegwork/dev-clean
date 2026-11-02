import Foundation
import Testing
@testable import DevCleanCore

private let GiB: UInt64 = 1 << 30
private let GB: UInt64 = 1_000_000_000

private func snapshot(diskFree: UInt64 = 200 * GB, swapUsed: UInt64 = 0, swapTotal: UInt64 = 4 * GiB,
                      pressure: MemoryPressure = .normal, uptimeDays: Double = 1) -> SystemSnapshot {
    let now = Date()
    return SystemSnapshot(
        memory: MemorySnapshot(total: 24 * GiB, appMemory: 8 * GiB, wired: 2 * GiB, compressed: 1 * GiB,
                               cached: 2 * GiB, freePercent: 50, pressure: pressure),
        swap: SwapSnapshot(total: swapTotal, used: swapUsed),
        disk: DiskSnapshot(total: 500 * GB, free: diskFree, availableForImportantUsage: diskFree),
        bootTime: now.addingTimeInterval(-uptimeDays * 86_400),
        takenAt: now)
}

@Suite struct InsightsTests {
    @Test func healthySystemHasNoInsights() {
        let insights = Insights.evaluate(system: snapshot(), processes: [])
        #expect(insights.isEmpty)
        #expect(Insights.overall(insights) == .ok)
    }

    @Test func lowDiskIsWarningThenCritical() {
        let warning = Insights.evaluate(system: snapshot(diskFree: 15 * GB), processes: [])
        #expect(warning.first { $0.id == "disk" }?.severity == .warning)

        let critical = Insights.evaluate(system: snapshot(diskFree: 8 * GB), processes: [])
        #expect(critical.first { $0.id == "disk" }?.severity == .critical)
    }

    @Test func nearlyFullSwapIsFlagged() {
        let insights = Insights.evaluate(system: snapshot(swapUsed: 19 * GiB, swapTotal: 20 * GiB), processes: [])
        #expect(insights.contains { $0.id == "swap" && $0.title == "Swap is 95% full" })
    }

    @Test func longUptimeSuggestsRestart() {
        let insights = Insights.evaluate(system: snapshot(uptimeDays: 29), processes: [])
        #expect(insights.contains { $0.id == "uptime" && $0.severity == .info })
    }

    @Test func leakingLoginwindowIsFlagged() {
        let leak = ProcessSample(pid: 1, name: "loginwindow", executablePath: nil, footprint: 2 * GiB, startTime: nil)
        let insights = Insights.evaluate(system: snapshot(), processes: [leak])
        #expect(insights.contains { $0.id == "leak-loginwindow" })
    }

    @Test func sortedMostSevereFirst() {
        let insights = Insights.evaluate(system: snapshot(diskFree: 5 * GB, uptimeDays: 30), processes: [])
        #expect(insights.map(\.severity) == [.critical, .info])
    }
}
