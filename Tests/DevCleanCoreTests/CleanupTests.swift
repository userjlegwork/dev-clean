import Foundation
import Testing
@testable import DevCleanCore

/// Every test works in its own temp "home". Nothing here touches real caches.
private final class Sandbox {
    let root: URL
    var home: String { root.path }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devclean-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 16) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func dir(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func target(_ method: CleanupMethod, blocking: [String] = [], blockingPaths: [String] = []) -> CleanupTarget {
        CleanupTarget(id: "t", name: "T", detail: "", method: method, measuredPaths: [], blockingProcesses: blocking,
                      blockingExecutablePaths: blockingPaths, allowedRoot: home)
    }
}

private let nothingRunning = RunningProcesses(names: [], executablePaths: [])

@Suite struct SafetyTests {
    @Test func refusesShallowOrOutsidePaths() throws {
        let box = try Sandbox()
        let shallow = try box.dir(".npm")
        let deep = try box.dir(".npm/_cacache")
        #expect(!CleanupRunner.isSafeDirectory(box.home, allowedRoot: box.home))
        #expect(!CleanupRunner.isSafeDirectory(shallow, allowedRoot: box.home))
        #expect(!CleanupRunner.isSafeDirectory("/", allowedRoot: box.home))
        #expect(!CleanupRunner.isSafeDirectory("/usr/local/lib", allowedRoot: box.home))
        #expect(!CleanupRunner.isSafeDirectory(box.home + "/.npm/../.npm", allowedRoot: box.home))
        #expect(CleanupRunner.isSafeDirectory(deep, allowedRoot: box.home))
    }

    @Test func refusesSymlinkedFolder() throws {
        let box = try Sandbox()
        let real = try box.dir("elsewhere/precious")
        try box.file("elsewhere/precious/keep.txt")
        try FileManager.default.createDirectory(atPath: box.home + "/.cache", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: box.home + "/.cache/link", withDestinationPath: real)

        let target = box.target(.deleteContents(box.home + "/.cache/link"))
        #expect(throws: CleanupError.self) { try CleanupRunner.removableItems(target) }
        #expect(FileManager.default.fileExists(atPath: real + "/keep.txt"))
    }

    @Test func refusesRootOutsideAllowedRootEvenWhenItExists() async throws {
        let box = try Sandbox()
        let other = try Sandbox()
        let victim = try other.dir("a/b")
        try other.file("a/b/keep.txt")
        let target = box.target(.deleteContents(victim))
        let result = await CleanupRunner.run(target, running: nothingRunning)
        #expect(result.error != nil)
        #expect(FileManager.default.fileExists(atPath: victim + "/keep.txt"))
    }
}

@Suite struct DeleteTests {
    @Test func deleteContentsKeepsTheFolder() async throws {
        let box = try Sandbox()
        try box.file(".npm/_cacache/index/a", bytes: 4_096)
        try box.file(".npm/_cacache/content/b", bytes: 4_096)
        let cache = box.home + "/.npm/_cacache"

        let target = box.target(.deleteContents(cache))
        #expect(CleanupRunner.estimate(target) == 0) // measuredPaths empty
        let result = await CleanupRunner.run(target, running: nothingRunning)

        #expect(result.error == nil)
        #expect(result.removedItems == 2)
        #expect(FileManager.default.fileExists(atPath: cache))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache).isEmpty)
    }

    @Test func planIsADryRun() throws {
        let box = try Sandbox()
        try box.file(".npm/_cacache/x")
        let target = box.target(.deleteContents(box.home + "/.npm/_cacache"))

        let plan = CleanupRunner.plan(target, running: nothingRunning)
        #expect(plan.canRun)
        #expect(plan.actions.first?.hasPrefix("Delete 1 item in") == true)
        #expect(FileManager.default.fileExists(atPath: box.home + "/.npm/_cacache/x"))
    }

    @Test func oldVersionSelection() {
        let names = ["chromium-1208", "chromium-1228", "chromium-1248",
                     "chromium_headless_shell-1208", "chromium_headless_shell-1248",
                     "ffmpeg-1011", "ffmpeg-1013", "webkit-2248", "webkit-2311", ".links", "README"]
        #expect(CleanupRunner.oldVersions(names) == [
            "chromium-1208", "chromium-1228", "chromium_headless_shell-1208", "ffmpeg-1011", "webkit-2248",
        ])
    }

    @Test func deleteOldVersionsKeepsNewest() async throws {
        let box = try Sandbox()
        for name in ["chromium-1208/x", "chromium-1248/x", "webkit-2248/x", ".links/y"] {
            try box.file("Library/Caches/ms-playwright/" + name, bytes: 8_192)
        }
        let folder = box.home + "/Library/Caches/ms-playwright"
        let target = box.target(.deleteOldVersions(folder))
        #expect(CleanupRunner.estimate(target) >= 8_192)

        let result = await CleanupRunner.run(target, running: nothingRunning)
        #expect(result.removedItems == 1)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder)) == ["chromium-1248", "webkit-2248", ".links"])
    }
}

@Suite struct BlockingTests {
    @Test func blockedTargetDoesNothing() async throws {
        let box = try Sandbox()
        try box.file("Library/Developer/Xcode/DerivedData/App-abc/Build")
        let target = box.target(.deleteContents(box.home + "/Library/Developer/Xcode/DerivedData"), blocking: ["Xcode"])
        let running = RunningProcesses(names: ["Xcode", "Finder"], executablePaths: [])

        #expect(CleanupRunner.plan(target, running: running).blockedBy == ["Xcode"])
        let result = await CleanupRunner.run(target, running: running)
        #expect(result.error == "Quit Xcode first")
        #expect(FileManager.default.fileExists(atPath: box.home + "/Library/Developer/Xcode/DerivedData/App-abc/Build"))
    }

    @Test func blockedByExecutableFolder() {
        let target = CleanupTarget(id: "p", name: "P", detail: "", method: .deleteOldVersions("/h/Library/Caches/ms-playwright"),
                                   measuredPaths: [], blockingExecutablePaths: ["/h/Library/Caches/ms-playwright"], allowedRoot: "/h")
        let safari = RunningProcesses(names: ["com.apple.WebKit.WebContent"],
                                      executablePaths: ["/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent"])
        let tests = RunningProcesses(names: ["chrome-headless-shell"],
                                     executablePaths: ["/h/Library/Caches/ms-playwright/chromium_headless_shell-1208/chrome-headless-shell"])
        #expect(CleanupRunner.blockers(for: target, running: safari).isEmpty)
        #expect(!CleanupRunner.blockers(for: target, running: tests).isEmpty)
    }
}

@Suite struct CommandTests {
    @Test func capturesOutputAndStatus() async {
        let ok = await CommandRunner.run("/bin/sh", ["-c", "echo hello; echo oops >&2"])
        #expect(ok.status == 0)
        #expect(ok.output.contains("hello") && ok.output.contains("oops"))

        let failed = await CommandRunner.run("/bin/sh", ["-c", "echo bad; exit 3"])
        #expect(failed.status == 3)
        #expect(failed.tail == "bad")
    }

    @Test func timesOut() async {
        let output = await CommandRunner.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        #expect(output.timedOut)
    }

    @Test func missingToolIsReportedNotRun() async throws {
        let box = try Sandbox()
        let target = box.target(.command(executables: [box.home + "/nope/uv"], arguments: ["cache", "clean"]))
        #expect(CleanupRunner.plan(target, running: nothingRunning).error == "uv isn't installed")
    }
}

@Suite struct CatalogAndLogTests {
    @Test func catalogOnlyListsExistingFolders() throws {
        let box = try Sandbox()
        _ = try box.dir(".npm/_cacache")
        _ = try box.dir("Library/Caches/pip")
        let ids = CleanupCatalog.standard(home: box.home).map(\.id)
        #expect(ids == ["npm", "pip"])
    }

    @Test func everyDeleteTargetIsSafeByConstruction() {
        // The real catalog's delete folders must all pass the depth rule relative to home.
        let home = "/Users/someone"
        for target in CleanupCatalog.standard(home: home, fileExists: { _ in true }) {
            switch target.method {
            case .deleteContents(let path), .deleteOldVersions(let path):
                let depth = path.dropFirst(home.count + 1).split(separator: "/").count
                #expect(depth >= 2, "\(target.id) deletes too close to home")
            case .command, .simulators:
                break
            }
        }
    }

    @Test func sizerCountsFiles() throws {
        let box = try Sandbox()
        try box.file("a/b/c.bin", bytes: 1 << 20)
        #expect(DirectorySizer.allocatedSize(of: box.home + "/a") >= 1 << 20)
    }

    @Test func logRoundTrips() throws {
        let box = try Sandbox()
        let log = CleanupLog(url: box.root.appendingPathComponent("logs/cleanup.log"))
        let result = CleanupResult(targetID: "npm", succeeded: true, message: "ok", removedItems: 2, freedBytes: 1_000)
        log.append(.init(date: Date(timeIntervalSince1970: 0), target: "npm cache", action: "Delete 2 items", estimatedBytes: 2_000, result: result))
        log.append(.init(date: Date(timeIntervalSince1970: 60), target: "pip cache", action: "Delete 1 item", estimatedBytes: 10, result: result))
        #expect(log.entries().map(\.target) == ["npm cache", "pip cache"])
    }
}

@Suite struct SimulatorTests {
    @Test func parsesSimctlJSON() {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
            {"udid": "A", "name": "iPhone 16", "isAvailable": true, "state": "Shutdown"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
            {"udid": "B", "name": "iPhone 14", "isAvailable": false, "availabilityError": "runtime profile not found"}
          ]
        }}
        """
        let devices = Simulators.parse(Data(json.utf8))
        #expect(devices.map(\.udid) == ["B", "A"])
        #expect(devices.first { !$0.isAvailable }?.runtime == "iOS-16-4")
        #expect(Simulators.parse(Data("not json".utf8)).isEmpty)
    }

    @Test func zeroBytesReadsAsNumber() {
        #expect(Format.disk(0).hasPrefix("0"))
    }
}
