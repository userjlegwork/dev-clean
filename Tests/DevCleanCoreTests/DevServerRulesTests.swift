import Darwin
import Foundation
import Testing
@testable import DevCleanCore

private let home = "/Users/me"

private func server(pid: Int32, root: String, startedDaysAgo days: Double, protected: Bool = false,
                    now: Date) -> DevServer {
    DevServer(
        process: ProcessSample(pid: pid, name: "python", executablePath: nil, footprint: 100,
                               startTime: now.addingTimeInterval(-days * 86_400)),
        kind: .django, arguments: [], workingDirectory: root, port: nil, projectRoot: root, isProtected: protected)
}

@Suite struct ProtectionTests {
    let rules = DevServerRules(protectedPaths: ["/Users/me/acubliss", "/opt/homebrew/var"])

    @Test func mainCheckoutIsProtected() {
        #expect(rules.isProtected(["/Users/me/acubliss/core"]))
        #expect(rules.isProtected(["/opt/homebrew/var/postgresql@16"]))
    }

    @Test func worktreesAndSiblingsAreNot() {
        #expect(!rules.isProtected(["/Users/me/.codex/worktrees/5e1e/acubliss/core"]))
        // A shared prefix that isn't a folder boundary doesn't count.
        #expect(!rules.isProtected(["/Users/me/acubliss-old/core"]))
    }

    @Test func tmpSymlinkResolves() {
        let tmpRules = DevServerRules(protectedPaths: ["/tmp/keep-me"])
        #expect(tmpRules.isProtected(["/private/tmp/keep-me/data"]))
    }
}

@Suite struct ProjectTests {
    let now = Date()

    @Test func staleOnlyWhenNewestServerIsOld() {
        let old = DevServerProject(root: "/w", servers: [
            server(pid: 1, root: "/w", startedDaysAgo: 3, now: now),
            server(pid: 2, root: "/w", startedDaysAgo: 2, now: now),
        ])
        #expect(old.isStale(after: 86_400, now: now))

        let restarted = DevServerProject(root: "/w", servers: [
            server(pid: 1, root: "/w", startedDaysAgo: 3, now: now),
            server(pid: 2, root: "/w", startedDaysAgo: 0.1, now: now),
        ])
        #expect(!restarted.isStale(after: 86_400, now: now))
    }

    @Test func protectedProjectIsNeverStale() {
        let project = DevServerProject(root: "/w", servers: [
            server(pid: 1, root: "/w", startedDaysAgo: 20, protected: true, now: now),
            server(pid: 2, root: "/w", startedDaysAgo: 20, now: now),
        ])
        #expect(project.isProtected)
        #expect(!project.isStale(after: 86_400, now: now))
    }

    @Test func displayNames() {
        func name(_ root: String) -> String { DevServerProject(root: root, servers: []).displayName(home: home) }
        #expect(name("/Users/me/.codex/worktrees/5e1e/acubliss") == "5e1e · acubliss (Codex)")
        #expect(name("/Users/me/projects/finances") == "~/projects/finances")
        #expect(name("/private/tmp/acubliss-pr13268-review") == "/tmp/acubliss-pr13268-review")
    }

    @Test func gitRootFindsWorktreeFile() {
        let markers: Set<String> = ["/Users/me/.codex/worktrees/5e1e/acubliss/.git"]
        let root = DevServerScanner.gitRoot(from: "/Users/me/.codex/worktrees/5e1e/acubliss/client/webui") { markers.contains($0) }
        #expect(root == "/Users/me/.codex/worktrees/5e1e/acubliss")
        #expect(DevServerScanner.gitRoot(from: "/tmp/nowhere") { _ in false } == nil)
    }
}

@Suite(.serialized) struct StopperTests {
    private func spawn(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }

    private func target(_ process: Process) -> StopTarget {
        let pid = process.processIdentifier
        return StopTarget(pid: pid, startTime: ProcessScanner.startTime(pid: pid))
    }

    @Test func politeStop() async throws {
        let process = try spawn("exec sleep 60")
        let report = await ProcessStopper.stop([target(process)], grace: .seconds(3), poll: .milliseconds(50))
        #expect(report.stopped == [process.processIdentifier])
        #expect(report.forced.isEmpty && report.failed.isEmpty)
    }

    @Test func forcesProcessIgnoringSigterm() async throws {
        // Ignored signals survive exec, so `sleep` itself ignores SIGTERM.
        let process = try spawn("trap '' TERM; exec sleep 60")
        try await Task.sleep(for: .milliseconds(200))
        let report = await ProcessStopper.stop([target(process)], grace: .milliseconds(500), poll: .milliseconds(50))
        #expect(report.forced == [process.processIdentifier])
        #expect(report.failed.isEmpty)
    }

    @Test func scanThenStopFakeDjangoProject() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("devclean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("core"), withIntermediateDirectories: true)
        try "import time\ntime.sleep(60)\n".write(to: project.appendingPathComponent("core/manage.py"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: project) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["manage.py", "runserver", "127.0.0.1:18999"]
        process.currentDirectoryURL = project.appendingPathComponent("core")
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let rootPath = DevServerRules.normalize(project.path)
        func find(_ rules: DevServerRules) -> DevServerProject? {
            DevServerScanner.scan(ProcessScanner.scan(), rules: rules)
                .first { DevServerRules.normalize($0.root) == rootPath }
        }

        // The first python3 launch after a build can be slow (xcrun shim), so poll rather than sleep once.
        var scanned: DevServerProject?
        for _ in 0..<50 where scanned == nil {
            try await Task.sleep(for: .milliseconds(100))
            scanned = find(DevServerRules(protectedPaths: []))
        }
        let found = try #require(scanned)
        #expect(found.servers.map(\.label).contains("Django :18999"))
        #expect(!found.isProtected)
        #expect(find(DevServerRules(protectedPaths: [project.path]))?.isProtected == true)

        let report = await ProcessStopper.stop(found.servers.map(\.stopTarget), grace: .seconds(3), poll: .milliseconds(50))
        #expect(report.failed.isEmpty)
        #expect(!report.stopped.isEmpty || !report.forced.isEmpty)
        #expect(find(DevServerRules(protectedPaths: [])) == nil)
    }

    @Test func reusedPidIsLeftAlone() async throws {
        let process = try spawn("exec sleep 60")
        defer { process.terminate() }
        // Same PID, wrong start time: must be treated as already gone and not signalled.
        let stale = StopTarget(pid: process.processIdentifier, startTime: Date(timeIntervalSince1970: 0))
        let report = await ProcessStopper.stop([stale], grace: .milliseconds(200), poll: .milliseconds(50))
        #expect(report.stopped == [process.processIdentifier])
        #expect(process.isRunning)
    }
}
