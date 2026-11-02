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

/// Read-only: lists worktrees with their safety status, and large files. Removes nothing. Run with:
/// DEVCLEAN_LIVE=1 swift test --filter LiveWorktreePreview
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVCLEAN_LIVE"] != nil))
struct LiveWorktreePreview {
    @Test func printWorktrees() async {
        let clock = ContinuousClock()
        let start = clock.now
        let processes = RunningProcess.current()
        var removable = 0
        for repository in Worktrees.repositories(extra: ["~/acubliss"]) {
            print("Repository \(repository)")
            for worktree in await Worktrees.list(repository: repository) {
                let status = await Worktrees.status(worktree, processes: processes)
                let blockers = status.blockers(for: worktree, protectedPaths: DevServerRules.defaultProtectedPaths)
                if blockers.isEmpty { removable += 1 }
                let age = status.lastActivity.map { Format.age(since: $0) } ?? "?"
                print("  \(worktree.displayName()) \(age) \(worktree.isPrunable ? "[prunable]" : "") \(blockers.isEmpty ? "removable" : blockers.joined(separator: "; "))")
            }
        }
        print("Removable: \(removable), status took \(clock.now - start)")

        let sizeStart = clock.now
        let size = DirectorySizer.allocatedSize(of: NSHomeDirectory() + "/.codex/worktrees/02d8/acubliss")
        print("One worktree sized \(Format.disk(size)) in \(clock.now - sizeStart)")
    }

    @Test func printLargeFiles() async {
        let clock = ContinuousClock()
        let start = clock.now
        let files = await LargeFileFinder.find()
        for file in files {
            print("  \(Format.disk(file.size)) \(LargeFileFinder.canTrash(file.path) ? "trash" : "reveal") \((file.path as NSString).abbreviatingWithTildeInPath)")
        }
        print("\(files.count) files in \(clock.now - start)")
    }
}
