import Foundation

public enum Severity: Int, Sendable, Comparable {
    case ok, info, warning, critical

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Insight: Sendable, Identifiable, Equatable {
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
}

public struct Thresholds: Sendable {
    /// Below this, disk is a warning; below half of it, critical (swap can no longer grow).
    public var minFreeDisk: UInt64 = 20_000_000_000
    public var swapWarningFraction: Double = 0.8
    public var maxUptimeDays: Int = 14
    /// Processes known to leak over long uptimes, with the footprint at which to flag them.
    public var leakyProcesses: [String: UInt64] = ["loginwindow": 1 << 30]

    public init() {}
}

public enum Insights {
    public static func evaluate(system: SystemSnapshot, processes: [ProcessSample],
                                staleProjects: [DevServerProject] = [],
                                thresholds: Thresholds = Thresholds()) -> [Insight] {
        var insights: [Insight] = []

        if !staleProjects.isEmpty {
            let servers = staleProjects.reduce(0) { $0 + $1.servers.count }
            let footprint = staleProjects.reduce(0) { $0 + $1.footprint }
            insights.append(Insight(
                id: "stale-servers", severity: .info,
                title: "\(servers) stale dev server\(servers == 1 ? "" : "s") in \(staleProjects.count) project\(staleProjects.count == 1 ? "" : "s")",
                detail: "Using \(Format.memory(footprint)). Stop them from the Dev servers tab."))
        }

        switch system.memory.pressure {
        case .normal: break
        case .warning:
            insights.append(Insight(id: "pressure", severity: .warning, title: "Memory pressure is elevated",
                                    detail: "macOS is compressing and swapping memory. Quit apps you aren't using."))
        case .critical:
            insights.append(Insight(id: "pressure", severity: .critical, title: "Memory pressure is critical",
                                    detail: "macOS may start force-quitting apps. Quit something large now."))
        }

        let diskFree = system.disk.free
        if diskFree < thresholds.minFreeDisk {
            let critical = diskFree < thresholds.minFreeDisk / 2
            insights.append(Insight(
                id: "disk", severity: critical ? .critical : .warning,
                title: "Only \(Format.disk(diskFree)) of disk free",
                detail: critical
                    ? "Swap lives on this disk and can no longer grow. Free space before memory runs out."
                    : "Under \(Format.disk(thresholds.minFreeDisk)). Clear caches or old worktrees soon."))
        }

        if system.swap.total > 0, system.swap.usedFraction >= thresholds.swapWarningFraction {
            let percent = Int((system.swap.usedFraction * 100).rounded())
            insights.append(Insight(
                id: "swap", severity: .warning,
                title: "Swap is \(percent)% full",
                detail: "\(Format.memory(system.swap.used)) of \(Format.memory(system.swap.total)). A restart clears it."))
        }

        if system.uptimeDays > thresholds.maxUptimeDays {
            insights.append(Insight(
                id: "uptime", severity: .info,
                title: "Up \(system.uptimeDays) days. Restart recommended",
                detail: "Long uptimes let swap and leaking system processes grow."))
        }

        for (name, limit) in thresholds.leakyProcesses.sorted(by: { $0.key < $1.key }) {
            let total = processes.filter { $0.name == name }.reduce(0) { $0 + $1.footprint }
            if total > limit {
                insights.append(Insight(
                    id: "leak-\(name)", severity: .warning,
                    title: "\(name) is using \(Format.memory(total))",
                    detail: "Known to leak. Only logging out or restarting frees it."))
            }
        }

        return insights.sorted { $0.severity > $1.severity }
    }

    public static func overall(_ insights: [Insight]) -> Severity {
        insights.map(\.severity).max() ?? .ok
    }
}
