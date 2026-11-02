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
    private(set) var insights: [Insight] = []
    private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?

    init(interval: Duration = .seconds(5)) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        let (snapshot, samples) = await Task.detached(priority: .utility) {
            (Result { try SystemMetrics.snapshot() }, ProcessScanner.scan())
        }.value

        processes = samples.sorted { $0.footprint > $1.footprint }
        apps = ProcessScanner.group(samples)
        switch snapshot {
        case .success(let system):
            self.system = system
            insights = Insights.evaluate(system: system, processes: samples)
            lastError = nil
        case .failure(let error):
            lastError = String(describing: error)
        }
    }
}
