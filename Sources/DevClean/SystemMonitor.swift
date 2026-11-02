import DevCleanCore
import Foundation
import Observation

/// Polls system metrics and processes off the main thread and publishes the latest sample.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var system: SystemSnapshot?
    private(set) var processes: [ProcessSample] = []
    private(set) var apps: [AppGroup] = []
    private(set) var projects: [DevServerProject] = []
    private(set) var insights: [Insight] = []
    private(set) var lastError: String?

    /// Project roots currently being stopped.
    private(set) var stopping: Set<String> = []
    private(set) var lastStopSummary: String?

    var protectedPaths: [String] {
        didSet { UserDefaults.standard.set(protectedPaths, forKey: Keys.protectedPaths) }
    }
    var staleAfterHours: Int {
        didSet { UserDefaults.standard.set(staleAfterHours, forKey: Keys.staleAfterHours) }
    }

    var rules: DevServerRules {
        DevServerRules(protectedPaths: protectedPaths, staleAfter: TimeInterval(staleAfterHours) * 3_600)
    }

    var staleProjects: [DevServerProject] {
        let rules = rules
        return projects.filter { $0.isStale(after: rules.staleAfter) }
    }

    private enum Keys {
        static let protectedPaths = "protectedPaths"
        static let staleAfterHours = "staleAfterHours"
    }

    private var pollTask: Task<Void, Never>?

    init(interval: Duration = .seconds(5)) {
        let defaults = UserDefaults.standard
        protectedPaths = defaults.stringArray(forKey: Keys.protectedPaths) ?? DevServerRules.defaultProtectedPaths
        let hours = defaults.integer(forKey: Keys.staleAfterHours)
        staleAfterHours = hours > 0 ? hours : 24

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        let rules = rules
        let (snapshot, samples, projects) = await Task.detached(priority: .utility) {
            let samples = ProcessScanner.scan()
            return (Result { try SystemMetrics.snapshot() }, samples, DevServerScanner.scan(samples, rules: rules))
        }.value

        processes = samples.sorted { $0.footprint > $1.footprint }
        apps = ProcessScanner.group(samples)
        self.projects = projects
        switch snapshot {
        case .success(let system):
            self.system = system
            insights = Insights.evaluate(system: system, processes: samples, staleProjects: staleProjects)
            lastError = nil
        case .failure(let error):
            lastError = String(describing: error)
        }
    }

    /// Stops every server in the given projects. Protected projects are skipped even if passed in.
    func stop(_ projects: [DevServerProject]) async {
        let targets = projects.filter { !$0.isProtected && !stopping.contains($0.root) }
        guard !targets.isEmpty else { return }
        let roots = Set(targets.map(\.root))
        stopping.formUnion(roots)
        defer { stopping.subtract(roots) }

        let report = await ProcessStopper.stop(targets.flatMap { $0.servers.map(\.stopTarget) })
        let names = targets.count == 1 ? targets[0].displayName() : "\(targets.count) projects"
        lastStopSummary = "\(names): \(report.summary)"
        await refresh()
    }

    func addProtectedPath(_ path: String) {
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath
        guard !protectedPaths.contains(abbreviated) else { return }
        protectedPaths.append(abbreviated)
        Task { await refresh() }
    }

    func removeProtectedPath(_ path: String) {
        protectedPaths.removeAll { $0 == path }
        Task { await refresh() }
    }
}
