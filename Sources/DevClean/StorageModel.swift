import DevCleanCore
import Foundation
import Observation

/// Sizes cleanup targets on demand and runs the selected ones, measuring real free-space change.
@MainActor
@Observable
final class StorageModel {
    let targets: [CleanupTarget]
    private(set) var sizes: [String: UInt64] = [:]
    private(set) var sizing: Set<String> = []
    private(set) var lastScan: Date?
    private(set) var plans: [String: CleanupPlan] = [:]
    var selected: Set<String>

    private(set) var runningTarget: String?
    private(set) var results: [CleanupResult] = []
    private(set) var summary: String?

    let log = CleanupLog.standard

    var isRunning: Bool { runningTarget != nil }
    var selectedEstimate: UInt64 { selected.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    init(targets: [CleanupTarget] = CleanupCatalog.standard()) {
        self.targets = targets
        selected = Set(targets.filter(\.selectedByDefault).map(\.id))
    }

    /// Sizes every target in parallel. Big caches (hundreds of thousands of files) take a while.
    func scan() async {
        guard sizing.isEmpty else { return }
        sizing = Set(targets.map(\.id))
        refreshPlans()
        await withTaskGroup(of: (String, UInt64).self) { group in
            for target in targets {
                group.addTask(priority: .utility) { (target.id, CleanupRunner.estimate(target)) }
            }
            for await (id, size) in group {
                sizes[id] = size
                sizing.remove(id)
            }
        }
        lastScan = Date()
    }

    /// Dry run: what each target would do and whether something running blocks it.
    func refreshPlans() {
        let running = RunningProcesses.current()
        plans = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, CleanupRunner.plan($0, running: running)) })
    }

    func clean(diskFree: @escaping @MainActor () -> UInt64?) async {
        guard !isRunning else { return }
        let chosen = targets.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }

        results = []
        summary = nil
        let start = diskFree()

        for target in chosen {
            runningTarget = target.id
            let running = RunningProcesses.current()
            let plan = CleanupRunner.plan(target, running: running)
            let before = diskFree()
            let outcome = await CleanupRunner.run(target, running: running)
            // APFS can take a moment to return freed blocks.
            try? await Task.sleep(for: .seconds(1))
            let freed = Int64(diskFree() ?? 0) - Int64(before ?? 0)

            let result = CleanupResult(targetID: target.id, succeeded: outcome.error == nil,
                                       message: outcome.error ?? "Done", removedItems: outcome.removedItems,
                                       freedBytes: max(freed, 0))
            results.append(result)
            log.append(.init(date: Date(), target: target.name, action: plan.actions.joined(separator: "; "),
                             estimatedBytes: sizes[target.id] ?? 0, result: result))
        }
        runningTarget = nil

        let totalFreed = max(Int64(diskFree() ?? 0) - Int64(start ?? 0), 0)
        let estimated = chosen.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
        let failures = results.filter { !$0.succeeded }.count
        var text = "Freed \(Format.disk(UInt64(totalFreed))) of an estimated \(Format.disk(estimated))."
        if UInt64(totalFreed) < estimated / 2 {
            text += " The rest was shared with installed projects (clones and hard links), so deleting it frees nothing."
        }
        if failures > 0 { text += " \(failures) didn't finish; see below." }
        summary = text

        await scan()
    }
}
