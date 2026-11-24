import Foundation
import Testing
@testable import DevCleanCore

/// Read-only: sizes the real disk-usage folders and lists Codex orphans. Deletes nothing and doesn't
/// touch the saved history. Run with:
/// DEVCLEAN_LIVE=1 swift test --filter LiveDiskUsage
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVCLEAN_LIVE"] != nil))
struct LiveDiskUsage {
    @Test func printBiggestFoldersAndOrphans() async {
        var registered: Set<String> = []
        for repository in Worktrees.repositories() {
            for worktree in await Worktrees.list(repository: repository) { registered.insert(worktree.path) }
        }
        let orphans = Worktrees.orphans(registered: registered)
        print("Codex worktrees registered: \(registered.filter { $0.contains("/.codex/worktrees/") }.count), orphans: \(orphans.count)")
        for orphan in orphans {
            let status = await Worktrees.status(orphan, processes: RunningProcess.current())
            print("  \(orphan.displayName()) blockers: \(status.blockers(for: orphan))")
        }

        let start = Date()
        let snapshot = await DiskUsage.scan(DiskUsage.folders()) { nil }
        print("Scanned \(snapshot.folders.count) folders in \(Int(Date().timeIntervalSince(start)))s, measured \(Format.disk(snapshot.measured))")
        for (path, bytes) in snapshot.folders.sorted(by: { $0.value > $1.value }).prefix(15) {
            print("  \(Format.disk(bytes))\t\(DiskUsage.displayPath(path))\t[\(DiskUsage.kind(of: path).label)]")
        }
    }
}
