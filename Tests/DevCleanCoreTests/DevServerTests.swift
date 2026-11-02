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
