import Foundation
import Testing
@testable import DevCleanCore

/// A bare "remote", a clone of it and a linked worktree, all in a temp folder.
private final class GitSandbox {
    let root: URL
    var repo: String { root.path + "/repo" }
    var worktree: String { root.path + "/wt" }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devclean-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try sh("git init -q --bare remote.git && git clone -q remote.git repo 2>/dev/null")
        try sh("cd repo && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm a && git push -q origin HEAD:main")
        try sh("cd repo && git worktree add -q --detach ../wt HEAD")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func sh(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw CleanupError.missingExecutable(script) }
    }

    func listed() async throws -> Worktree {
        try #require(await Worktrees.list(repository: repo).first)
    }
}

@Suite(.serialized) struct WorktreeTests {
    @Test func parsesPorcelainAndSkipsMainCheckout() {
        let porcelain = """
        worktree /Users/me/acubliss
        HEAD fb69
        branch refs/heads/telehealth-breaks

        worktree /private/tmp/old-ui
        HEAD 93ba
        detached
        prunable gitdir file points to non-existent location

        worktree /Users/me/.codex/worktrees/5e1e/acubliss
        HEAD 11fa
        branch refs/heads/feature
        locked reason

        """
        let list = Worktrees.parse(porcelain, repository: "/Users/me/acubliss")
        #expect(list.map(\.path) == ["/private/tmp/old-ui", "/Users/me/.codex/worktrees/5e1e/acubliss"])
        #expect(list[0].isPrunable && list[0].branch == nil && !list[0].isLocked)
        #expect(list[1].isLocked && list[1].branch == "feature" && list[1].head == "11fa")
        #expect(list[1].displayName(home: "/Users/me") == "5e1e · acubliss")
        #expect(list[0].displayName(home: "/Users/me") == "/tmp/old-ui")
    }

    @Test func reflogDateAndOfflineCheck() throws {
        let line = "a5b8 ade7 Jose Luis <j@x.com> 1793402697 -0300\tcommit: Keep work hours"
        #expect(Worktrees.reflogDate(line) == Date(timeIntervalSince1970: 1_793_402_697))
        #expect(Worktrees.reflogDate("garbage") == nil)
        #expect(!Worktrees.hasOfflineFiles(FileManager.default.temporaryDirectory.path))
    }

    @Test func repositoryFromGitFile() {
        #expect(Worktrees.repository(fromGitFile: "gitdir: /Users/me/acubliss/.git/worktrees/acubliss6\n") == "/Users/me/acubliss")
        #expect(Worktrees.repository(fromGitFile: "gitdir: /Users/me/x/.git/modules/sub") == nil)
    }

    @Test func blockersCoverEveryReason() {
        let wt = Worktree(path: "/Users/me/acubliss/wt", repository: "/Users/me/acubliss", isLocked: true, isPrunable: false)
        let status = WorktreeStatus(changedFiles: 2, unpushedCommits: 1, processes: ["node"])
        let reasons = status.blockers(for: wt, protectedPaths: ["/Users/me/acubliss"])
        #expect(reasons == ["Locked", "In a protected folder", "2 uncommitted changes", "1 commit not on any remote", "In use by node"])
        let free = Worktree(path: "/tmp/wt", repository: "/r", isLocked: false, isPrunable: false)
        #expect(WorktreeStatus().blockers(for: free).isEmpty)
    }

    @Test func processInsideIsFoundByCwdOrExecutable() {
        let processes = [
            RunningProcess(name: "zsh", workingDirectory: "/private/tmp/wt/src", executablePath: "/bin/zsh"),
            RunningProcess(name: "esbuild", workingDirectory: "/", executablePath: "/tmp/wt/node_modules/.bin/esbuild"),
            RunningProcess(name: "zsh", workingDirectory: "/tmp/wt", executablePath: "/bin/zsh"),
            RunningProcess(name: "vim", workingDirectory: "/tmp/wt2", executablePath: "/usr/bin/vim"),
        ]
        #expect(Worktrees.processesInside("/tmp/wt", processes) == ["zsh", "esbuild"])
    }

    @Test func cleanPushedWorktreeIsRemovable() async throws {
        let box = try GitSandbox()
        let wt = try await box.listed()
        let status = await Worktrees.status(wt, processes: [])
        #expect(status.blockers(for: wt).isEmpty)
        #expect(status.lastActivity != nil)

        // Ignored files don't block, and go with the worktree.
        try box.sh("echo node_modules >> repo/.git/info/exclude && mkdir wt/node_modules && echo x > wt/node_modules/x")
        #expect(await Worktrees.status(wt, processes: []).changedFiles == 0)

        #expect(await Worktrees.remove(wt, protectedPaths: []) == nil)
        #expect(!FileManager.default.fileExists(atPath: box.worktree))
        #expect(await Worktrees.list(repository: box.repo).isEmpty)
    }

    @Test func dirtyOrUnpushedWorktreeIsKept() async throws {
        let box = try GitSandbox()
        let wt = try await box.listed()

        try box.sh("cd wt && echo new > untracked.txt")
        var status = await Worktrees.status(wt, processes: [])
        #expect(status.changedFiles == 1)
        #expect(await Worktrees.remove(wt, protectedPaths: []) != nil)
        #expect(FileManager.default.fileExists(atPath: box.worktree + "/untracked.txt"))

        try box.sh("cd wt && git add untracked.txt && git -c user.email=t@t -c user.name=t commit -qm local")
        status = await Worktrees.status(wt, processes: [])
        #expect(status.changedFiles == 0 && status.unpushedCommits == 1)
        #expect(await Worktrees.remove(wt, protectedPaths: []) != nil)

        try box.sh("cd wt && git push -q origin HEAD:refs/heads/pushed")
        #expect(await Worktrees.status(wt, processes: []).unpushedCommits == 0)
    }

    @Test func missingFolderIsPruned() async throws {
        let box = try GitSandbox()
        try FileManager.default.removeItem(atPath: box.worktree)
        let wt = try await box.listed()
        #expect(wt.isPrunable)
        #expect(await Worktrees.remove(wt, protectedPaths: []) == nil)
        #expect(await Worktrees.list(repository: box.repo).isEmpty)
    }
}

@Suite struct LargeFileTests {
    private func home() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("devclean-lf-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ path: String, bytes: Int) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    @Test func walkFindsBigFilesAndSkipsHeavyFolders() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(home + "/.models/big.bin", bytes: 3_000_000)
        try write(home + "/.models/small.bin", bytes: 10_000)
        try write(home + "/.models/node_modules/huge.bin", bytes: 3_000_000)
        try write(home + "/.codex/worktrees/1/big.bin", bytes: 3_000_000)
        try write(home + "/.Trash/old.bin", bytes: 3_000_000)

        let found = LargeFileFinder.walk(LargeFileFinder.hiddenFolders(home: home), minimumSize: 2_000_000, home: home)
        #expect(found == [home + "/.models/big.bin"])
        #expect(LargeFileFinder.file(at: home + "/.models/big.bin", minimumSize: 2_000_000)?.size ?? 0 >= 2_000_000)
    }

    @Test func excludesPhoneAndCloudMounts() {
        let home = "/Users/me"
        #expect(LargeFileFinder.isExcluded("/Users/me/Library/CloudStorage/MacDroid-Pixel7/DCIM/a.mp4", home: home))
        #expect(LargeFileFinder.isExcluded("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.zip", home: home))
        #expect(!LargeFileFinder.isExcluded("/Users/me/Downloads/a.zip", home: home))
    }

    @Test func trashOnlyRealFilesOutsideLibrary() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(home + "/Downloads/a.zip", bytes: 10)
        try write(home + "/Library/Containers/docker/Docker.raw", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: home + "/Downloads/link.zip", withDestinationPath: home + "/Downloads/a.zip")

        #expect(LargeFileFinder.canTrash(home + "/Downloads/a.zip", home: home))
        #expect(!LargeFileFinder.canTrash(home + "/Library/Containers/docker/Docker.raw", home: home))
        #expect(!LargeFileFinder.canTrash(home + "/Downloads/link.zip", home: home))
        #expect(!LargeFileFinder.canTrash(home + "/Downloads/../../etc/hosts", home: home))
        #expect(!LargeFileFinder.canTrash(home + "/Downloads", home: home))
        await #expect(throws: CleanupError.self) {
            try await LargeFileFinder.moveToTrash(home + "/Library/Containers/docker/Docker.raw", home: home)
        }
    }

    @Test func openFilesAreDetectedAndNotTrashed() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let open = home + "/Downloads/open.db", closed = home + "/Downloads/closed.db"
        try write(open, bytes: 10)
        try write(closed, bytes: 10)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: open))
        defer { try? handle.close() }

        #expect(await LargeFileFinder.openPaths([open, closed]) == [open])
        await #expect(throws: CleanupError.inUse(open)) { try await LargeFileFinder.moveToTrash(open, home: home) }
        #expect(FileManager.default.fileExists(atPath: open))
    }
}
