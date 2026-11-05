import Foundation

/// A linked git worktree (never the main checkout).
public struct Worktree: Sendable, Identifiable, Equatable {
    public var path: String
    /// The main checkout that owns it.
    public var repository: String
    public var head: String?
    /// Short branch name, nil when detached.
    public var branch: String?
    public var isLocked: Bool
    /// Folder is gone; only git's bookkeeping is left.
    public var isPrunable: Bool

    public var id: String { path }

    /// "5e1e · acubliss" for Codex worktrees, otherwise the path with ~ and /tmp shortened.
    public func displayName(home: String = NSHomeDirectory()) -> String {
        let path = DevServerRules.normalize(path)
        let codex = home + "/.codex/worktrees/"
        if path.hasPrefix(codex) {
            let parts = path.dropFirst(codex.count).split(separator: "/")
            if parts.count == 2 { return "\(parts[0]) · \(parts[1])" }
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

/// What makes removal unsafe, read right before acting.
public struct WorktreeStatus: Sendable, Equatable {
    public var changedFiles: Int
    public var unpushedCommits: Int
    /// Last checkout or commit, from the worktree's reflog.
    public var lastActivity: Date?
    /// Processes whose working directory or executable is inside the worktree.
    public var processes: [RunningProcess]
    /// git couldn't read it; treat as unsafe.
    public var error: String?

    public init(changedFiles: Int = 0, unpushedCommits: Int = 0, lastActivity: Date? = nil,
                processes: [RunningProcess] = [], error: String? = nil) {
        self.changedFiles = changedFiles
        self.unpushedCommits = unpushedCommits
        self.lastActivity = lastActivity
        self.processes = processes
        self.error = error
    }

    /// Reasons not to remove. Empty means `git worktree remove` (without --force) can go ahead.
    public func blockers(for worktree: Worktree, protectedPaths: [String] = []) -> [String] {
        var reasons: [String] = []
        if let error { reasons.append(error) }
        if worktree.isLocked { reasons.append("Locked") }
        if DevServerRules(protectedPaths: protectedPaths).isProtected([worktree.path]) { reasons.append("In a protected folder") }
        if changedFiles > 0 { reasons.append("\(changedFiles) uncommitted change\(changedFiles == 1 ? "" : "s")") }
        if unpushedCommits > 0 { reasons.append("\(unpushedCommits) commit\(unpushedCommits == 1 ? "" : "s") not on any remote") }
        if !processes.isEmpty { reasons.append("In use by \(processNames.prefix(3).joined(separator: ", "))") }
        return reasons
    }

    /// Distinct names of the processes inside, in order.
    public var processNames: [String] {
        var seen = Set<String>()
        return processes.map(\.name).filter { seen.insert($0).inserted }
    }
}

public enum Worktrees {
    static let git = "/usr/bin/git"

    // MARK: - Discovery

    /// Main checkouts that own Codex worktrees (~/.codex/worktrees/<id>/<repo>), plus any extra repositories.
    public static func repositories(home: String = NSHomeDirectory(), extra: [String] = []) -> [String] {
        let codex = home + "/.codex/worktrees"
        var found: [String] = []
        let fm = FileManager.default
        for id in (try? fm.contentsOfDirectory(atPath: codex)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: "\(codex)/\(id)")) ?? [] where !name.hasPrefix(".") {
                if let contents = try? String(contentsOfFile: "\(codex)/\(id)/\(name)/.git", encoding: .utf8),
                   let repository = repository(fromGitFile: contents) {
                    found.append(repository)
                }
            }
        }
        var seen = Set<String>()
        return (found + extra.map { ($0 as NSString).expandingTildeInPath })
            .map(DevServerRules.normalize)
            .filter { seen.insert($0).inserted }
    }

    /// "gitdir: /repo/.git/worktrees/name" → "/repo".
    static func repository(fromGitFile contents: String) -> String? {
        guard let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir: "),
              let range = line.range(of: "/.git/worktrees/") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: "gitdir: ".count)..<range.lowerBound])
    }

    // MARK: - Listing

    public static func list(repository: String) async -> [Worktree] {
        let output = await CommandRunner.run(git, ["-C", repository, "worktree", "list", "--porcelain"], timeout: .seconds(30))
        guard output.status == 0 else { return [] }
        return parse(output.output, repository: repository)
    }

    /// Parses `git worktree list --porcelain`, dropping the first entry (the main checkout).
    static func parse(_ porcelain: String, repository: String) -> [Worktree] {
        var worktrees: [Worktree] = []
        var current: Worktree?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { worktrees.append(current) }
                current = Worktree(path: String(line.dropFirst("worktree ".count)), repository: repository,
                                   isLocked: false, isPrunable: false)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = line.dropFirst("branch ".count)
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.isLocked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.isPrunable = true
            }
        }
        if let current { worktrees.append(current) }
        return Array(worktrees.dropFirst())
    }

    // MARK: - Status

    /// Reads everything `blockers` needs. `processes` maps a running process label to its cwd and executable.
    public static func status(_ worktree: Worktree, processes: [RunningProcess]) async -> WorktreeStatus {
        guard !worktree.isPrunable else { return WorktreeStatus() }
        let activity = lastActivity(worktree.path)

        // git status would make iCloud download every offloaded file (and hang meanwhile).
        if hasOfflineFiles(worktree.path) {
            return WorktreeStatus(lastActivity: activity, error: "Files are offloaded to iCloud, so changes can't be checked")
        }

        let changes = await CommandRunner.run(git, ["-C", worktree.path, "status", "--porcelain"], timeout: .seconds(30))
        guard changes.status == 0, !changes.timedOut else {
            return WorktreeStatus(lastActivity: activity,
                                  error: changes.timedOut ? "git status timed out" : "git status failed: \(changes.tail)")
        }
        let unpushed = await CommandRunner.run(git, ["-C", worktree.path, "rev-list", "--count", "HEAD", "--not", "--remotes"],
                                               timeout: .seconds(30))
        guard unpushed.status == 0, let count = Int(unpushed.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return WorktreeStatus(lastActivity: activity, error: "Couldn't compare with remotes: \(unpushed.tail)")
        }

        return WorktreeStatus(
            changedFiles: changes.output.split(whereSeparator: \.isNewline).count,
            unpushedCommits: count,
            lastActivity: activity,
            processes: processesInside(worktree.path, processes))
    }

    /// Time of the last reflog entry (checkout, commit, reset). The reflog file's own date isn't used:
    /// `git gc` rewrites it.
    static func lastActivity(_ path: String) -> Date? {
        guard let contents = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir: ") else { return nil }
        let gitDir = String(line.dropFirst("gitdir: ".count))
        if let reflog = try? String(contentsOfFile: gitDir + "/logs/HEAD", encoding: .utf8),
           let last = reflog.split(whereSeparator: \.isNewline).last, let date = reflogDate(String(last)) {
            return date
        }
        return (try? FileManager.default.attributesOfItem(atPath: gitDir + "/HEAD"))?[.modificationDate] as? Date
    }

    /// "<old> <new> Name <email> 1793402697 -0300\tcommit: …" → the timestamp.
    static func reflogDate(_ line: String) -> Date? {
        guard let header = line.split(separator: "\t").first, let close = header.lastIndex(of: ">") else { return nil }
        let fields = header[header.index(after: close)...].split(separator: " ")
        return fields.first.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
    }

    /// True if any top-level file has been offloaded (APFS "dataless": contents live only in iCloud).
    static func hasOfflineFiles(_ path: String) -> Bool {
        let dataless: UInt32 = 0x4000_0000 // SF_DATALESS
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return entries.prefix(50).contains { name in
            var info = stat()
            return lstat(path + "/" + name, &info) == 0 && info.st_flags & dataless != 0
        }
    }

    static func processesInside(_ path: String, _ processes: [RunningProcess]) -> [RunningProcess] {
        let root = DevServerRules(protectedPaths: [path])
        let me = getpid()
        return processes.filter { $0.pid != me && root.isProtected([$0.workingDirectory, $0.executablePath].compactMap { $0 }) }
    }

    // MARK: - Removal

    /// Re-checks status, then runs `git worktree remove` without --force, so git itself refuses
    /// if anything changed since the check. Ignored files (node_modules, .env) go with it.
    public static func remove(_ worktree: Worktree, protectedPaths: [String]) async -> String? {
        if worktree.isPrunable { return await prune(repository: worktree.repository) }
        let status = await status(worktree, processes: RunningProcess.current())
        let blockers = status.blockers(for: worktree, protectedPaths: protectedPaths)
        guard blockers.isEmpty else { return blockers.joined(separator: "; ") }

        let output = await CommandRunner.run(git, ["-C", worktree.repository, "worktree", "remove", worktree.path],
                                             timeout: .seconds(300))
        return output.status == 0 ? nil : "git refused: \(output.tail)"
    }

    // MARK: - Stopping and forcing

    /// Stops whatever is running inside the worktree: SIGTERM, then SIGKILL after `grace`.
    /// Looks the processes up again first, so only what's inside right now is signalled.
    public static func stopProcesses(in worktree: Worktree, protectedPaths: [String],
                                     grace: Duration = .seconds(5)) async -> StopReport? {
        guard !DevServerRules(protectedPaths: protectedPaths).isProtected([worktree.path]) else { return nil }
        let inside = processesInside(worktree.path, RunningProcess.current())
        return await ProcessStopper.stop(inside.map { StopTarget(pid: $0.pid, startTime: $0.startTime) }, grace: grace)
    }

    public struct ForceRemoval: Sendable, Equatable {
        /// Where the folder went, nil if it was already gone.
        public var trashedTo: URL?
        /// Branch created to keep unpushed commits of a detached worktree.
        public var backupBranch: String?
    }

    public enum ForceError: Error, Equatable, CustomStringConvertible {
        case protected
        case inUse([String])
        case failed(String)

        public var description: String {
            switch self {
            case .protected: "In a protected folder"
            case .inUse(let names): "Still in use by \(names.joined(separator: ", ")); stop it first"
            case .failed(let message): message
            }
        }
    }

    /// Removes a worktree git won't remove on its own (uncommitted changes, unpushed commits, locked,
    /// unreadable). Nothing is deleted outright: the folder goes to the Trash with its uncommitted changes,
    /// and unpushed commits on a detached HEAD are kept on a backup branch. Branches stay in the repository.
    public static func forceRemove(_ worktree: Worktree, protectedPaths: [String]) async throws(ForceError) -> ForceRemoval {
        guard !DevServerRules(protectedPaths: protectedPaths).isProtected([worktree.path]) else { throw .protected }
        let inside = processesInside(worktree.path, RunningProcess.current())
        guard inside.isEmpty else { throw .inUse(WorktreeStatus(processes: inside).processNames) }

        var result = ForceRemoval()
        if worktree.branch == nil, let head = worktree.head {
            result.backupBranch = try await backUpDetached(head: head, worktree: worktree)
        }
        if worktree.isLocked {
            let unlock = await CommandRunner.run(git, ["-C", worktree.repository, "worktree", "unlock", worktree.path],
                                                 timeout: .seconds(30))
            guard unlock.status == 0 else { throw .failed("git worktree unlock failed: \(unlock.tail)") }
        }
        if FileManager.default.fileExists(atPath: worktree.path) {
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: worktree.path), resultingItemURL: &trashed)
                result.trashedTo = trashed as URL?
            } catch {
                throw .failed("Couldn't move it to the Trash: \(error.localizedDescription)")
            }
        }
        if let error = await prune(repository: worktree.repository) { throw .failed(error) }
        return result
    }

    /// Detached commits not on any remote would only be reachable through the worktree's reflog,
    /// which goes with it. Pins them to "devclean-backup/<short sha>".
    static func backUpDetached(head: String, worktree: Worktree) async throws(ForceError) -> String? {
        let count = await CommandRunner.run(git, ["-C", worktree.repository, "rev-list", "--count", head, "--not", "--remotes"],
                                            timeout: .seconds(30))
        guard count.status == 0, let unpushed = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .failed("Couldn't check for unpushed commits: \(count.tail)")
        }
        guard unpushed > 0 else { return nil }
        let name = "devclean-backup/\(head.prefix(7))"
        let branch = await CommandRunner.run(git, ["-C", worktree.repository, "branch", "-f", name, head], timeout: .seconds(30))
        guard branch.status == 0 else { throw .failed("Couldn't save unpushed commits to \(name): \(branch.tail)") }
        return name
    }

    /// Drops bookkeeping for worktrees whose folders are already gone.
    public static func prune(repository: String) async -> String? {
        let output = await CommandRunner.run(git, ["-C", repository, "worktree", "prune"], timeout: .seconds(60))
        return output.status == 0 ? nil : "git worktree prune failed: \(output.tail)"
    }
}

/// A process's name, cwd and executable, for "is anything running in this folder?" checks.
public struct RunningProcess: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var workingDirectory: String?
    public var executablePath: String?
    /// Lets a later stop skip a reused PID.
    public var startTime: Date?

    public init(pid: Int32 = 0, name: String, workingDirectory: String?, executablePath: String?, startTime: Date? = nil) {
        self.pid = pid
        self.name = name
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
        self.startTime = startTime
    }

    public static func current() -> [RunningProcess] {
        ProcessScanner.allPIDs().compactMap { pid in
            guard let name = ProcessScanner.shortName(pid: pid) else { return nil }
            return RunningProcess(pid: pid, name: name, workingDirectory: ProcessScanner.workingDirectory(pid: pid),
                                  executablePath: ProcessScanner.executablePath(pid: pid),
                                  startTime: ProcessScanner.startTime(pid: pid))
        }
    }
}
