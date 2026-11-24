import Foundation
import Testing
@testable import DevCleanCore

private let GB: UInt64 = 1_000_000_000

/// A fake home folder in a temp directory.
private final class TempHome {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("devclean-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: "\(path)/\(relative)", withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ contents: String = "x") throws {
        try mkdir((relative as NSString).deletingLastPathComponent)
        try contents.write(toFile: "\(path)/\(relative)", atomically: true, encoding: .utf8)
    }

    /// Backdates everything under `relative` so it looks untouched.
    func age(_ relative: String, by interval: TimeInterval) throws {
        let date = Date().addingTimeInterval(-interval)
        let root = "\(path)/\(relative)"
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root)
        for item in FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? [] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: "\(root)/\(item)")
        }
    }
}

@Suite struct GrowthTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snap(_ minutes: Double, free: UInt64 = 100 * GB, _ folders: [String: UInt64]) -> UsageSnapshot {
        UsageSnapshot(date: start.addingTimeInterval(minutes * 60), free: free, folders: folders)
    }

    @Test func reportsFoldersThatGrewBiggestFirst() {
        let base = snap(0, ["/h/.codex": 14 * GB, "/h/Downloads": 7 * GB, "/h/projects": 12 * GB])
        let latest = snap(60, ["/h/.codex": 33 * GB, "/h/Downloads": 7 * GB, "/h/projects": 16 * GB, "/h/new": 5 * GB])
        let growth = Growth.detect(latest: latest, history: [base])
        #expect(growth.map(\.path) == ["/h/.codex", "/h/new", "/h/projects"])
        #expect(growth[0].bytes == 19 * GB && growth[0].interval == 3_600)
        #expect(Growth.duration(growth[0].interval) == "1h")
    }

    @Test func ignoresSmallGrowthAndShrinking() {
        let base = snap(0, ["/h/a": 10 * GB, "/h/b": 10 * GB])
        let latest = snap(60, ["/h/a": 12 * GB, "/h/b": 2 * GB])
        #expect(Growth.detect(latest: latest, history: [base]).isEmpty)
    }

    @Test func baselineIsNewestSnapshotInTheWindow() {
        let tooOld = snap(-2_000, ["/h/a": 1 * GB])
        let good = snap(-60, ["/h/a": 2 * GB])
        let newer = snap(-120, ["/h/a": 3 * GB])
        let tooRecent = snap(-5, ["/h/a": 4 * GB])
        let latest = snap(0, ["/h/a": 10 * GB])
        #expect(Growth.baseline(for: latest, in: [tooOld, newer, good, tooRecent]) == good)
        #expect(Growth.baseline(for: latest, in: [tooOld, tooRecent]) == nil)
        #expect(Growth.detect(latest: latest, history: [tooRecent]).isEmpty)
    }

    @Test func scansAfterLaunchEveryFewHoursAndWhenFreeSpaceDrops() {
        let launched = start
        #expect(!Growth.shouldScan(now: start.addingTimeInterval(30), free: 50 * GB, last: nil, launched: launched))
        #expect(Growth.shouldScan(now: start.addingTimeInterval(180), free: 50 * GB, last: nil, launched: launched))

        let last = snap(0, free: 61 * GB, [:])
        let at = { (minutes: Double) in start.addingTimeInterval(minutes * 60) }
        #expect(!Growth.shouldScan(now: at(60), free: 60 * GB, last: last, launched: launched))
        #expect(Growth.shouldScan(now: at(60), free: 42 * GB, last: last, launched: launched))
        // A big drop right after a scan waits for the minimum interval.
        #expect(!Growth.shouldScan(now: at(5), free: 42 * GB, last: last, launched: launched))
        #expect(Growth.shouldScan(now: at(6 * 60), free: 61 * GB, last: last, launched: launched))
    }

    @Test func growthBecomesAWarningInsight() {
        let growth = [FolderGrowth(path: NSHomeDirectory() + "/.codex", bytes: 19 * GB, interval: 3_600),
                      FolderGrowth(path: NSHomeDirectory() + "/projects", bytes: 4 * GB, interval: 3_600)]
        let system = SystemSnapshot(
            memory: MemorySnapshot(total: 24 << 30, appMemory: 8 << 30, wired: 2 << 30, compressed: 1 << 30,
                                   cached: 2 << 30, freePercent: 50, pressure: .normal),
            swap: SwapSnapshot(total: 4 << 30, used: 0),
            disk: DiskSnapshot(total: 500 * GB, free: 200 * GB, availableForImportantUsage: 200 * GB),
            bootTime: Date(), takenAt: Date())
        let insight = Insights.evaluate(system: system, processes: [], growth: growth).first { $0.id == "growth" }
        #expect(insight?.severity == .warning)
        #expect(insight?.title == "~/.codex grew 19 GB in 1h")
        #expect(insight?.detail.contains("~/projects +4 GB") == true)
    }
}

@Suite struct DiskUsageTests {
    @Test func foldersSplitLibraryAndSkipOtherAppsSandboxes() throws {
        let home = try TempHome()
        for folder in [".codex", "Downloads", "Library/Caches/Google", "Library/Application Support/Claude",
                       "Library/Containers/com.docker.docker", "Library/CloudStorage/Pixel", "Library/Android"] {
            try home.mkdir(folder)
        }
        try home.write("loose-file.txt")
        let folders = DiskUsage.folders(home: home.path, extra: []).map { String($0.dropFirst(home.path.count + 1)) }
        #expect(Set(folders) == [".codex", "Downloads", "Library/Android", "Library/Caches/Google",
                                 "Library/Application Support/Claude"])
    }

    @Test func scanSizesEachFolderAndSkipsPhotoLibraries() async throws {
        let home = try TempHome()
        try home.write("Downloads/big.bin", String(repeating: "x", count: 200_000))
        try home.write("Pictures/Photos Library.photoslibrary/originals/a.jpg", String(repeating: "x", count: 200_000))
        let snapshot = await DiskUsage.scan(DiskUsage.folders(home: home.path, extra: [])) { 42 }
        #expect(snapshot.free == 42)
        #expect(snapshot.folders[home.path + "/Downloads", default: 0] >= 200_000)
        #expect(snapshot.folders[home.path + "/Pictures"] == 0)
    }

    @Test func labelsWhatDeletingMeans() {
        let home = "/Users/me"
        #expect(DiskUsage.kind(of: "/Users/me/Library/Caches/Google", home: home) == .rebuilds)
        #expect(DiskUsage.kind(of: "/Users/me/.npm", home: home) == .rebuilds)
        #expect(DiskUsage.kind(of: "/Users/me/.codex", home: home) == .app)
        #expect(DiskUsage.kind(of: "/Users/me/Library/Application Support/Claude", home: home) == .app)
        #expect(DiskUsage.kind(of: "/opt/homebrew", home: home) == .app)
        #expect(DiskUsage.kind(of: "/Users/me/PixelBackup", home: home) == .yours)
        #expect(DiskUsage.kind(of: "/Users/me/.Trash", home: home) == .yours)
        #expect(DiskUsage.hint(for: "/Users/me/.codex", home: home)?.contains("Worktrees") == true)
    }

    @Test func historyIsTrimmedAndRoundTrips() throws {
        let home = try TempHome()
        let now = Date()
        let old = UsageSnapshot(date: now.addingTimeInterval(-20 * 86_400), free: 1, folders: [:])
        let recent = (0..<70).map { UsageSnapshot(date: now.addingTimeInterval(Double(-$0) * 60), free: 2, folders: ["/a": 1]) }
        let trimmed = UsageHistory.trimmed([old] + recent, now: now)
        #expect(trimmed.count == UsageHistory.maxSnapshots)
        #expect(!trimmed.contains(old))
        #expect(trimmed.first!.date < trimmed.last!.date)

        let url = URL(fileURLWithPath: home.path + "/state/history.json")
        try UsageHistory.save(trimmed, to: url)
        let loaded = UsageHistory.load(from: url)
        #expect(loaded.count == trimmed.count)
        #expect(abs(loaded.last!.date.timeIntervalSince(trimmed.last!.date)) < 1)
        #expect(UsageHistory.load(from: URL(fileURLWithPath: home.path + "/missing.json")).isEmpty)
    }
}

@Suite(.serialized) struct OrphanWorktreeTests {
    /// ~/.codex/worktrees with a registered worktree, an empty leftover, a dangling checkout and a full clone.
    private func makeCodex(_ home: TempHome) throws {
        try home.write(".codex/worktrees/live/app/.git", "gitdir: \(home.path)/repo/.git/worktrees/app\n")
        try home.mkdir("repo/.git/worktrees/app")
        try home.write(".codex/worktrees/empty/.codex-worktree-name", "empty")
        try home.write(".codex/worktrees/gone/app/.git", "gitdir: \(home.path)/repo/.git/worktrees/gone\n")
        try home.write(".codex/worktrees/gone/app/node_modules/pkg/index.js")
        try home.write(".codex/worktrees/gone/app/src/main.ts")
    }

    @Test func findsFoldersGitForgot() throws {
        let home = try TempHome()
        try makeCodex(home)
        try home.write(".codex/worktrees/listed/app/README", "x")
        let orphans = Worktrees.orphans(home: home.path, registered: [home.path + "/.codex/worktrees/listed/app"])
        #expect(orphans.map { ($0.path as NSString).lastPathComponent } == ["empty", "gone"])
        #expect(orphans.allSatisfy { $0.isOrphan && $0.repository.isEmpty })
        #expect(orphans[0].contents.isEmpty && orphans[1].contents == ["app"])
        #expect(orphans[0].displayName(home: home.path) == "empty · empty")
        #expect(orphans[1].displayName(home: home.path) == "gone · app")
    }

    @Test func recentOrphanIsKeptOldOneIsDeleted() async throws {
        let home = try TempHome()
        try makeCodex(home)
        let gone = try #require(Worktrees.orphans(home: home.path, registered: []).first { $0.path.hasSuffix("/gone") })

        let fresh = await Worktrees.status(gone, processes: [])
        #expect(fresh.blockers(for: gone) == ["Changed in the last day"])

        try home.age(".codex/worktrees/gone", by: 3 * 86_400)
        let old = await Worktrees.status(gone, processes: [])
        #expect(old.blockers(for: gone).isEmpty)

        let busy = await Worktrees.status(gone, processes: [
            RunningProcess(pid: 1, name: "node", workingDirectory: gone.path + "/app", executablePath: nil)])
        #expect(busy.blockers(for: gone) == ["In use by node"])

        #expect(await Worktrees.deleteOrphan(gone, protectedPaths: [], home: home.path) == nil)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func refusesToDeleteOutsideCodexOrSymlinks() async throws {
        let home = try TempHome()
        try home.write("projects/keep/a.txt")
        try home.age("projects", by: 3 * 86_400)
        let outside = Worktree(path: home.path + "/projects/keep", repository: "", isLocked: false, isPrunable: false, isOrphan: true)
        #expect(await Worktrees.deleteOrphan(outside, protectedPaths: [], home: home.path) != nil)

        try home.mkdir(".codex/worktrees")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/.codex/worktrees/link",
                                                   withDestinationPath: home.path + "/projects/keep")
        let link = Worktree(path: home.path + "/.codex/worktrees/link", repository: "", isLocked: false, isPrunable: false, isOrphan: true)
        #expect(await Worktrees.deleteOrphan(link, protectedPaths: [], home: home.path) != nil)
        #expect(FileManager.default.fileExists(atPath: home.path + "/projects/keep/a.txt"))
        #expect(Worktrees.orphans(home: home.path, registered: []).isEmpty)
    }

    @Test func fullCloneWithUnpushedWorkIsKept() async throws {
        let home = try TempHome()
        try home.mkdir(".codex/worktrees/clone")
        let clone = home.path + "/.codex/worktrees/clone/app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "git init -q \(clone) && cd \(clone) && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm a && echo b > b"]
        try process.run()
        process.waitUntilExit()
        try home.age(".codex/worktrees/clone", by: 3 * 86_400)

        let orphan = try #require(Worktrees.orphans(home: home.path, registered: []).first)
        let status = await Worktrees.status(orphan, processes: [])
        #expect(status.changedFiles == 1 && status.unpushedCommits == 1)
        #expect(await Worktrees.deleteOrphan(orphan, protectedPaths: [], home: home.path) != nil)
        #expect(FileManager.default.fileExists(atPath: clone))
    }
}
