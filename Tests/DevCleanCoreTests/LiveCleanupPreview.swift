import Foundation
import Testing
@testable import DevCleanCore

/// Read-only: sizes the real cleanup targets and prints their dry-run plans. Deletes nothing. Run with:
/// DEVCLEAN_LIVE=1 swift test --filter LiveCleanupPreview
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVCLEAN_LIVE"] != nil))
struct LiveCleanupPreview {
    @Test func printPlans() async {
        let running = RunningProcesses.current()
        let targets = CleanupCatalog.standard()
        let sizes = await withTaskGroup(of: (String, UInt64).self) { group in
            for target in targets { group.addTask { (target.id, CleanupRunner.estimate(target)) } }
            var sizes: [String: UInt64] = [:]
            for await (id, size) in group { sizes[id] = size }
            return sizes
        }
        for target in targets {
            let plan = CleanupRunner.plan(target, running: running)
            let size = (target.isUpperBound ? "up to " : "") + Format.disk(sizes[target.id] ?? 0)
            let flags = [target.selectedByDefault ? "default" : nil,
                         plan.blockedBy.isEmpty ? nil : "BLOCKED by \(plan.blockedBy.joined(separator: ", "))",
                         plan.error.map { "ERROR \($0)" }].compactMap { $0 }
            print("\(target.name): \(size) \(flags.isEmpty ? "" : "[\(flags.joined(separator: "; "))]")")
            for action in plan.actions.prefix(6) { print("    → \(action)") }
        }
    }
}
