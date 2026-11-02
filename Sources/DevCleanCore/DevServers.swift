import Darwin
import Foundation

public enum DevServerKind: String, Sendable, CaseIterable {
    case django = "Django"
    case vite = "Vite"
    case esbuild = "esbuild"
    case celery = "Celery"
    case postgres = "Postgres"

    /// Postgres treats SIGTERM as "wait for clients"; SIGINT is its fast shutdown.
    public var stopSignal: Int32 { self == .postgres ? SIGINT : SIGTERM }
}

public struct DevServer: Sendable, Identifiable, Equatable {
    public var process: ProcessSample
    public var kind: DevServerKind
    public var arguments: [String]
    public var workingDirectory: String?
    public var port: Int?
    public var projectRoot: String
    public var isProtected: Bool

    public var id: Int32 { process.pid }

    public var label: String { port.map { "\(kind.rawValue) :\($0)" } ?? kind.rawValue }
    public var stopTarget: StopTarget {
        StopTarget(pid: process.pid, startTime: process.startTime, signal: kind.stopSignal)
    }
}

/// All dev servers sharing a project folder (a git checkout or a Postgres data dir).
public struct DevServerProject: Sendable, Identifiable, Equatable {
    public var root: String
    public var servers: [DevServer]

    public var id: String { root }
    /// One protected process protects the whole project.
    public var isProtected: Bool { servers.contains(where: \.isProtected) }
    public var footprint: UInt64 { servers.reduce(0) { $0 + $1.process.footprint } }
    public var newestStart: Date? { servers.compactMap(\.process.startTime).max() }
    public var oldestStart: Date? { servers.compactMap(\.process.startTime).min() }

    /// Stale only when every server in it is older than the cutoff, so a project you restarted today stays.
    public func isStale(after age: TimeInterval, now: Date = Date()) -> Bool {
        guard !isProtected, let newestStart else { return false }
        return now.timeIntervalSince(newestStart) >= age
    }

    /// "~/.codex/worktrees/5e1e/acubliss" → "5e1e · acubliss (Codex)"; otherwise the path with ~ for home.
    public func displayName(home: String = NSHomeDirectory()) -> String {
        let codexPrefix = home + "/.codex/worktrees/"
        if root.hasPrefix(codexPrefix) {
            let parts = root.dropFirst(codexPrefix.count).split(separator: "/")
            if parts.count >= 2 { return "\(parts[0]) · \(parts[1]) (Codex)" }
        }
        if root == home { return "~" }
        if root.hasPrefix(home + "/") { return "~" + root.dropFirst(home.count) }
        return root.hasPrefix("/private/tmp/") ? String(root.dropFirst("/private".count)) : root
    }
}

public struct DevServerRules: Sendable, Equatable {
    public static let defaultProtectedPaths = ["~/acubliss", "/opt/homebrew/var"]

    /// Folders whose servers are never stopped. Matched by prefix after expanding ~ and folding /private.
    public var protectedPaths: [String]
    public var staleAfter: TimeInterval

    public init(protectedPaths: [String] = DevServerRules.defaultProtectedPaths, staleAfter: TimeInterval = 86_400) {
        self.protectedPaths = protectedPaths
        self.staleAfter = staleAfter
    }

    public func isProtected(_ paths: [String]) -> Bool {
        let roots = protectedPaths.map(Self.normalize)
        return paths.map(Self.normalize).contains { path in
            roots.contains { root in path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        }
    }

    /// Pure string normalization (no filesystem access, so it works for folders that no longer exist).
    /// The kernel reports /tmp as /private/tmp; fold both to the short form.
    static func normalize(_ path: String) -> String {
        var normalized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        for linked in ["/tmp", "/var", "/etc"] where normalized == "/private" + linked || normalized.hasPrefix("/private" + linked + "/") {
            normalized = String(normalized.dropFirst("/private".count))
        }
        return normalized
    }
}

public enum DevServerScanner {
    /// Cheap name filter so argv and cwd are only read for plausible processes.
    static let candidatePrefixes = ["python", "node", "esbuild", "postgres", "uv", "celery", "watchmedo", "bun", "deno"]

    public static func scan(_ samples: [ProcessSample], rules: DevServerRules) -> [DevServerProject] {
        var gitRoots: [String: String] = [:]
        let servers = samples.compactMap { sample -> DevServer? in
            let lower = sample.name.lowercased()
            guard candidatePrefixes.contains(where: lower.hasPrefix),
                  let arguments = ProcessScanner.arguments(pid: sample.pid),
                  let kind = classify(executableName: sample.name, arguments: arguments) else { return nil }

            let cwd = ProcessScanner.workingDirectory(pid: sample.pid)
            let root = projectRoot(kind: kind, arguments: arguments, workingDirectory: cwd) { dir in
                if let cached = gitRoots[dir] { return cached }
                let found = gitRoot(from: dir)
                gitRoots[dir] = found
                return found
            }
            let paths = [cwd, root].compactMap { $0 } + arguments.filter { $0.hasPrefix("/") }
            return DevServer(process: sample, kind: kind, arguments: arguments, workingDirectory: cwd,
                             port: port(kind: kind, arguments: arguments), projectRoot: root,
                             isProtected: rules.isProtected(paths))
        }

        return Dictionary(grouping: servers, by: \.projectRoot)
            .map { DevServerProject(root: $0.key, servers: $0.value.sorted { $0.process.pid < $1.process.pid }) }
            .sorted { ($0.newestStart ?? .distantFuture) < ($1.newestStart ?? .distantFuture) }
    }

    public static func classify(executableName: String, arguments: [String]) -> DevServerKind? {
        let name = executableName.lowercased()
        if name == "esbuild" {
            // Vite's child runs `esbuild --service=<version> --ping`.
            return arguments.contains { $0 == "--service" || $0.hasPrefix("--service=") } ? .esbuild : nil
        }
        if name == "postgres" { return arguments.contains("-D") ? .postgres : nil }
        if arguments.contains("runserver"),
           arguments.contains(where: { $0 == "manage.py" || $0.hasSuffix("/manage.py") }) {
            return .django
        }
        if arguments.contains(where: { $0 == "vite" || $0.hasSuffix("/.bin/vite") || $0.hasSuffix("/vite/bin/vite.js") }) {
            return .vite
        }
        if arguments.contains(where: { $0 == "celery" || $0.hasSuffix("/celery") }), arguments.contains("worker") {
            return .celery
        }
        return nil
    }

    public static func port(kind: DevServerKind, arguments: [String]) -> Int? {
        switch kind {
        case .django:
            // `runserver`, `runserver 8001` or `runserver 127.0.0.1:8001`
            guard let index = arguments.firstIndex(of: "runserver"), index + 1 < arguments.count else { return nil }
            let address = arguments[index + 1]
            guard !address.hasPrefix("-") else { return nil }
            return address.split(separator: ":").last.flatMap { Int($0) }
        case .vite:
            return value(after: "--port", in: arguments).flatMap(Int.init)
        case .postgres:
            return value(after: "-p", in: arguments).flatMap(Int.init)
        case .esbuild, .celery:
            return nil
        }
    }

    /// Postgres belongs to its data dir; everything else to the git checkout it runs in.
    static func projectRoot(kind: DevServerKind, arguments: [String], workingDirectory: String?,
                            gitRoot: (String) -> String?) -> String {
        if kind == .postgres, let dataDir = value(after: "-D", in: arguments) {
            return dataDir
        }
        guard let workingDirectory else { return "Unknown folder" }
        return gitRoot(workingDirectory) ?? workingDirectory
    }

    static func gitRoot(from directory: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        var current = directory
        while current != "/" && !current.isEmpty {
            // `.git` is a directory in a checkout and a file in a worktree.
            if fileExists(current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}
