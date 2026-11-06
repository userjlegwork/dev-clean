import Darwin
import Foundation
import Testing
@testable import DevCleanCore

// Command lines below are real ones seen on this machine.

@Suite struct ClassifierTests {
    @Test func venvDjango() {
        let args = ["/Users/me/.codex/worktrees/5e1e/acubliss/core/.venv/bin/python", "manage.py", "runserver", "127.0.0.1:18869", "--noreload"]
        #expect(DevServerScanner.classify(executableName: "python3.12", arguments: args) == .django)
        #expect(DevServerScanner.port(kind: .django, arguments: args) == 18869)
    }

    @Test func uvWrappedDjangoWithoutPort() {
        let args = ["uv", "run", "/usr/bin/env", "DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib", "python", "manage.py", "runserver"]
        #expect(DevServerScanner.classify(executableName: "uv", arguments: args) == .django)
        #expect(DevServerScanner.port(kind: .django, arguments: args) == nil)
    }

    @Test func djangoShellIsNotAServer() {
        #expect(DevServerScanner.classify(executableName: "uv", arguments: ["uv", "run", "python", "manage.py", "shell"]) == nil)
    }

    @Test func vite() {
        let args = ["node", "/private/tmp/acubliss-pr13268-review/client/node_modules/.bin/vite", "--debug", "hmr", "--host", "127.0.0.1", "--port", "19753", "--strictPort"]
        #expect(DevServerScanner.classify(executableName: "node", arguments: args) == .vite)
        #expect(DevServerScanner.port(kind: .vite, arguments: args) == 19753)
        #expect(DevServerScanner.port(kind: .vite, arguments: ["node", "vite", "--port=5173"]) == 5173)
    }

    @Test func esbuildService() {
        let args = ["/x/node_modules/@esbuild/darwin-arm64/bin/esbuild", "--service=0.21.5", "--ping"]
        #expect(DevServerScanner.classify(executableName: "esbuild", arguments: args) == .esbuild)
        #expect(DevServerScanner.classify(executableName: "esbuild", arguments: ["esbuild", "src/index.ts"]) == nil)
    }

    @Test func celeryUnderWatchmedo() {
        let args = ["uv", "run", "--", "watchmedo", "auto-restart", "-d", ".", "--", "celery", "-A", "common", "worker", "-l", "info"]
        #expect(DevServerScanner.classify(executableName: "uv", arguments: args) == .celery)
    }

    @Test func postgresWithDataDir() {
        let args = ["/opt/homebrew/Cellar/postgresql@16/16.15_1/bin/postgres", "-D", "/private/tmp/amityville-synthetic-pg/data", "-p", "15876"]
        #expect(DevServerScanner.classify(executableName: "postgres", arguments: args) == .postgres)
        #expect(DevServerScanner.port(kind: .postgres, arguments: args) == 15876)
        let root = DevServerScanner.projectRoot(kind: .postgres, arguments: args, workingDirectory: "/") { _ in nil }
        #expect(root == "/private/tmp/amityville-synthetic-pg/data")
    }

    @Test func unrelatedNodeIsIgnored() {
        #expect(DevServerScanner.classify(executableName: "node", arguments: ["node", "server.bundle.js"]) == nil)
    }
}


/// Process trees as seen on this machine: one Django launch is 3 processes, one Celery worker 4,
/// and two separate Vite launches (one left behind when its terminal closed) are 2 each.
@Suite struct InstanceTests {
    let root = "/Users/me/acubliss"
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func sample(_ pid: Int32, _ parent: Int32, _ name: String, hoursIn: Double = 0) -> ProcessSample {
        ProcessSample(pid: pid, name: name, executablePath: nil, footprint: 10, startTime: start.addingTimeInterval(hoursIn * 3_600),
                      parentPID: parent)
    }

    func server(_ sample: ProcessSample, _ kind: DevServerKind, port: Int? = nil) -> DevServer {
        DevServer(process: sample, kind: kind, arguments: [], workingDirectory: root, port: port, projectRoot: root,
                  isProtected: false, instanceID: sample.pid)
    }

    @Test func groupsEachLaunchIntoOneInstance() {
        let shell = sample(8608, 900, "zsh")
        let uv = sample(16299, 8608, "uv"), reloader = sample(16300, 16299, "python3.13")
        let child = sample(2860, 16300, "python3.13", hoursIn: 24)
        let npm = sample(35859, 8700, "npm"), vite = sample(35860, 35859, "node"), esbuild = sample(35902, 35860, "esbuild")
        let oldVite = sample(51737, 1, "node", hoursIn: -500), oldEsbuild = sample(51740, 51737, "esbuild", hoursIn: -500)
        let samples = [shell, uv, reloader, child, npm, vite, esbuild, oldVite, oldEsbuild, sample(8700, 900, "zsh")]
        let servers = [server(uv, .django), server(reloader, .django), server(child, .django),
                       server(vite, .vite), server(esbuild, .esbuild),
                       server(oldVite, .vite, port: 19005), server(oldEsbuild, .esbuild)]

        let trees = DevServerScanner.instanceTrees(servers: servers, samples: samples) { sample in
            sample.name == "npm" ? ["npm", "run", "dev"] : nil
        }
        let project = DevServerProject(
            root: root,
            servers: servers.map { var s = $0; s.instanceID = trees.root[s.id] ?? s.id; return s },
            launchers: trees.launchers)
        let instances = project.instances

        #expect(instances.map(\.id) == [51737, 16299, 35859])
        #expect(instances.map(\.label) == ["Vite :19005", "Django", "Vite"])
        #expect(instances.map(\.processCount) == [2, 3, 3])
        #expect(instances.map(\.isDetached) == [true, false, false])
        // Django's serving child restarted a day later; the launch time is still uv's.
        #expect(instances[1].startTime == start && instances[1].newestStart == start.addingTimeInterval(86_400))
        // The npm wrapper is stopped first, before Vite and its esbuild.
        #expect(instances[2].stopTargets.map(\.pid) == [35859, 35860, 35902])
        #expect(project.stopTargets.count == 8)
    }

    @Test func recognizesLaunchers() {
        #expect(DevServerScanner.isLauncher(name: "uv", arguments: []))
        #expect(DevServerScanner.isLauncher(name: "Python", arguments: ["/opt/homebrew/bin/python3", "/Users/me/.local/bin/watchmedo", "auto-restart"]))
        #expect(!DevServerScanner.isLauncher(name: "zsh", arguments: ["-zsh"]))
        #expect(!DevServerScanner.isLauncher(name: "node", arguments: ["node", "server.js"]))
    }
}
