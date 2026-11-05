import DevCleanCore
import Foundation
import Observation

struct WorktreeRow: Identifiable {
    var worktree: Worktree
    var status: WorktreeStatus?
    var size: UInt64?
    var blockers: [String]
    var isProtected = false

    var id: String { worktree.id }
    var isRemovable: Bool { status != nil && blockers.isEmpty }
    /// Blocked, but the user can stop what's inside or force it out.
    var canForce: Bool { status != nil && !blockers.isEmpty && !isProtected && !worktree.isPrunable }
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
    private(set) var stopping: String?
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
            self.apply(status, to: id, protectedPaths: protectedPaths)
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

    // MARK: - Stop and force

    /// Stops the processes inside one worktree, then re-checks it.
    func stopProcesses(in row: WorktreeRow, protectedPaths: [String]) async {
        guard stopping == nil, !isRemoving else { return }
        stopping = row.id
        defer { stopping = nil }
        errors[row.id] = nil

        let names = row.status?.processNames.joined(separator: ", ") ?? "processes"
        guard let report = await Worktrees.stopProcesses(in: row.worktree, protectedPaths: protectedPaths) else {
            errors[row.id] = "In a protected folder"
            return
        }
        if !report.failed.isEmpty { errors[row.id] = "\(report.failed.count) wouldn't stop (owned by another user?)" }
        summary = "\(report.summary) in \(row.worktree.displayName()) (\(names))."
        log.append(.init(date: Date(), target: "Worktree \(row.worktree.displayName())", action: "Stop \(names)",
                         estimatedBytes: 0,
                         result: CleanupResult(targetID: "worktree-stop", succeeded: report.failed.isEmpty,
                                               message: report.summary, removedItems: 0, freedBytes: 0)))

        let worktree = row.worktree
        let status = await Worktrees.status(worktree, processes: await Task.detached { RunningProcess.current() }.value)
        apply(status, to: row.id, protectedPaths: protectedPaths)
    }

    /// Moves a blocked worktree to the Trash and drops it from git (see `Worktrees.forceRemove`).
    func forceRemove(_ row: WorktreeRow, protectedPaths: [String]) async {
        guard !isRemoving, stopping == nil else { return }
        removing = row.id
        defer { removing = nil }
        errors[row.id] = nil

        let target = "Worktree \(row.worktree.displayName())"
        let action = "Force remove \(row.worktree.path) (to Trash)"
        do {
            let removal = try await Worktrees.forceRemove(row.worktree, protectedPaths: protectedPaths)
            var text = "Moved \(row.worktree.displayName()) to the Trash. Empty the Trash to get \(Format.disk(row.size ?? 0)) back."
            if let branch = removal.backupBranch { text += " Its unpushed commits are on branch \(branch)." }
            summary = text
            rows.removeAll { $0.id == row.id }
            selected.remove(row.id)
            log.append(.init(date: Date(), target: target, action: action, estimatedBytes: row.size ?? 0,
                             result: CleanupResult(targetID: "worktree-force", succeeded: true, message: text,
                                                   removedItems: 1, freedBytes: 0)))
        } catch {
            errors[row.id] = error.description
            log.append(.init(date: Date(), target: target, action: action, estimatedBytes: row.size ?? 0,
                             result: CleanupResult(targetID: "worktree-force", succeeded: false, message: error.description,
                                                   removedItems: 0, freedBytes: 0)))
        }
    }

    private func apply(_ status: WorktreeStatus, to id: String, protectedPaths: [String]) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = status
        rows[index].blockers = status.blockers(for: rows[index].worktree, protectedPaths: protectedPaths)
        rows[index].isProtected = DevServerRules(protectedPaths: protectedPaths).isProtected([rows[index].worktree.path])
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
