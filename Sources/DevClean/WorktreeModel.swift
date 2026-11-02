import DevCleanCore
import Foundation
import Observation

struct WorktreeRow: Identifiable {
    var worktree: Worktree
    var status: WorktreeStatus?
    var size: UInt64?
    var blockers: [String]

    var id: String { worktree.id }
    var isRemovable: Bool { status != nil && blockers.isEmpty }
}

/// Lists linked git worktrees, checks each one is safe to remove, and removes the selected ones.
@MainActor
@Observable
final class WorktreeModel {
    private(set) var rows: [WorktreeRow] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    var selected: Set<String> = []

    private(set) var removing: String?
    private(set) var errors: [String: String] = [:]
    private(set) var summary: String?

    /// Repositories to check besides the ones Codex worktrees point to.
    var extraRepositories: [String] {
        didSet { UserDefaults.standard.set(extraRepositories, forKey: "worktreeRepositories") }
    }

    let log = CleanupLog.standard

    var isRemoving: Bool { removing != nil }
    var removableCount: Int { rows.filter(\.isRemovable).count }
    var selectedSize: UInt64 { rows.filter { selected.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) } }

    init() {
        extraRepositories = UserDefaults.standard.stringArray(forKey: "worktreeRepositories") ?? []
    }

    /// Status first (fast, decides what's removable), then sizes (slow: node_modules has many files).
    func scan(protectedPaths: [String], staleAfter: TimeInterval) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let extra = extraRepositories
        let processes = await Task.detached { RunningProcess.current() }.value
        var worktrees: [Worktree] = []
        for repository in Worktrees.repositories(extra: extra) {
            worktrees += await Worktrees.list(repository: repository)
        }
        rows = worktrees.map { WorktreeRow(worktree: $0, blockers: []) }

        await forEach(worktrees, width: 6) { worktree in
            (worktree.id, await Worktrees.status(worktree, processes: processes))
        } update: { id, status in
            guard let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
            self.rows[index].status = status
            self.rows[index].blockers = status.blockers(for: self.rows[index].worktree, protectedPaths: protectedPaths)
        }

        // Pre-select what's removable and untouched for a while; leave recent work for the user to tick.
        let cutoff = Date().addingTimeInterval(-staleAfter)
        selected = Set(rows.filter { row in
            row.isRemovable && (row.worktree.isPrunable || (row.status?.lastActivity ?? .distantFuture) < cutoff)
        }.map(\.id))
        sortRows()

        await forEach(worktrees.filter { !$0.isPrunable }, width: 4) { worktree in
            (worktree.id, DirectorySizer.allocatedSize(of: worktree.path))
        } update: { id, size in
            guard let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
            self.rows[index].size = size
        }
        lastScan = Date()
    }

    func remove(protectedPaths: [String], staleAfter: TimeInterval, diskFree: @escaping @MainActor () -> UInt64?) async {
        guard !isRemoving else { return }
        let chosen = rows.filter { selected.contains($0.id) && $0.isRemovable }
        guard !chosen.isEmpty else { return }

        errors = [:]
        summary = nil
        let start = diskFree()
        var removed = 0

        for row in chosen {
            removing = row.id
            let before = diskFree()
            let error = await Worktrees.remove(row.worktree, protectedPaths: protectedPaths)
            try? await Task.sleep(for: .seconds(1))
            let freed = max(Int64(diskFree() ?? 0) - Int64(before ?? 0), 0)
            if let error { errors[row.id] = error } else { removed += 1 }

            let action = row.worktree.isPrunable ? "git worktree prune" : "git worktree remove \(row.worktree.path)"
            log.append(.init(date: Date(), target: "Worktree \(row.worktree.displayName())", action: action,
                             estimatedBytes: row.size ?? 0,
                             result: CleanupResult(targetID: "worktree", succeeded: error == nil, message: error ?? "Done",
                                                   removedItems: error == nil ? 1 : 0, freedBytes: freed)))
        }
        removing = nil

        let totalFreed = UInt64(max(Int64(diskFree() ?? 0) - Int64(start ?? 0), 0))
        var text = "Removed \(removed) worktree\(removed == 1 ? "" : "s"), freeing \(Format.disk(totalFreed))."
        if !errors.isEmpty { text += " \(errors.count) kept; see the reasons below." }
        summary = text

        let kept = errors
        await scan(protectedPaths: protectedPaths, staleAfter: staleAfter)
        errors = kept
    }

    private func sortRows() {
        // Removable first, then oldest activity first.
        rows.sort { a, b in
            if a.isRemovable != b.isRemovable { return a.isRemovable }
            return (a.status?.lastActivity ?? .distantPast) < (b.status?.lastActivity ?? .distantPast)
        }
    }

    /// Runs `work` over `items` with at most `width` in flight, applying each result on the main actor as it lands.
    private func forEach<Item: Sendable, Result: Sendable>(
        _ items: [Item], width: Int,
        work: @escaping @Sendable (Item) async -> (String, Result),
        update: (String, Result) -> Void
    ) async {
        await withTaskGroup(of: (String, Result).self) { group in
            var pending = items[...]
            for _ in 0..<width {
                guard let item = pending.popFirst() else { break }
                group.addTask(priority: .utility) { await work(item) }
            }
            for await (id, result) in group {
                update(id, result)
                if let item = pending.popFirst() { group.addTask(priority: .utility) { await work(item) } }
            }
        }
    }
}
