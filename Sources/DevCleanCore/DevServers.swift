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
    /// PID at the top of the process tree this server belongs to (see `DevServerInstance`).
    public var instanceID: Int32

    public var id: Int32 { process.pid }

    public var label: String { port.map { "\(kind.rawValue) :\($0)" } ?? kind.rawValue }
    public var stopTarget: StopTarget {
        StopTarget(pid: process.pid, startTime: process.startTime, signal: kind.stopSignal)
    }
}

/// One launch of a server: the process you started plus everything it spawned. `uv run manage.py runserver`
/// is uv, Django's autoreloader and the serving child; a Celery worker is watchmedo, the main worker and its pool.
public struct DevServerInstance: Sendable, Identifiable, Equatable {
    public var id: Int32
    public var servers: [DevServer]
    /// Wrappers in the tree that aren't servers themselves (npm, pnpm), topmost first.
    /// Stopped first so they can't restart anything.
    public var launchers: [ProcessSample]

    public var primary: DevServer { servers.first { $0.kind != .esbuild } ?? servers[0] }
    public var kind: DevServerKind { primary.kind }
    public var port: Int? { servers.lazy.compactMap(\.port).first }
    public var label: String { port.map { "\(kind.rawValue) :\($0)" } ?? kind.rawValue }
    public var processCount: Int { servers.count + launchers.count }
    public var footprint: UInt64 { (servers.map(\.process) + launchers).reduce(0) { $0 + $1.footprint } }
    public var isProtected: Bool { servers.contains(where: \.isProtected) }
    /// When it was launched.
    public var startTime: Date? { (servers.map(\.process) + launchers).compactMap(\.startTime).min() }
    /// Last (re)start of any of its processes; Django's serving child restarts on every reload.
    public var newestStart: Date? { servers.compactMap(\.process.startTime).max() }
    /// The terminal or tool that started it is gone, so nothing will stop it on its own.
    public var isDetached: Bool {
        kind != .postgres && (launchers + servers.map(\.process)).first { $0.pid == id }?.parentPID == 1
    }

    public var stopTargets: [StopTarget] {
        launchers.map { StopTarget(pid: $0.pid, startTime: $0.startTime) } + servers.map(\.stopTarget)
    }

    public func isStale(after age: TimeInterval, now: Date = Date()) -> Bool {
        guard !isProtected, let newestStart else { return false }
        return now.timeIntervalSince(newestStart) >= age
    }
}

/// All dev servers sharing a project folder (a git checkout or a Postgres data dir).
public struct DevServerProject: Sendable, Identifiable, Equatable {
    public var root: String
    public var servers: [DevServer]
    /// Launchers by instance ID.
    public var launchers: [Int32: [ProcessSample]]

    public init(root: String, servers: [DevServer], launchers: [Int32: [ProcessSample]] = [:]) {
        self.root = root
        self.servers = servers
        self.launchers = launchers
    }

    public var id: String { root }

    /// Oldest launch first.
    public var instances: [DevServerInstance] {
        Dictionary(grouping: servers, by: \.instanceID)
            .map { DevServerInstance(id: $0.key, servers: $0.value, launchers: launchers[$0.key] ?? []) }
            .sorted { ($0.startTime ?? .distantFuture, $0.id) < ($1.startTime ?? .distantFuture, $1.id) }
    }
    public var stopTargets: [StopTarget] { instances.flatMap(\.stopTargets) }

    /// Older launches of a kind that also has a newer one running here, e.g. a Vite left behind by a closed
    /// terminal. These can be stopped even in a protected project: the newest of each kind keeps running.
    public var duplicateInstanceIDs: Set<Int32> {
        Set(Dictionary(grouping: instances, by: \.kind).values.flatMap { $0.dropLast() }.map(\.id))
    }
    /// One protected process protects the whole project.
    public var isProtected: Bool { servers.contains(where: \.isProtected) }
    public var footprint: UInt64 {
        servers.reduce(0) { $0 + $1.process.footprint } + launchers.values.joined().reduce(0) { $0 + $1.footprint }
    }
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
                             isProtected: rules.isProtected(paths), instanceID: sample.pid)
        }

        let trees = instanceTrees(servers: servers, samples: samples) { ProcessScanner.arguments(pid: $0.pid) }
        return Dictionary(grouping: servers, by: \.projectRoot)
            .map { root, servers in
                let servers = servers.map { server in
                    var server = server
                    server.instanceID = trees.root[server.id] ?? server.id
                    return server
                }
                let ids = Set(servers.map(\.instanceID))
                return DevServerProject(root: root, servers: servers.sorted { $0.process.pid < $1.process.pid },
                                        launchers: trees.launchers.filter { ids.contains($0.key) })
            }
            .sorted { ($0.newestStart ?? .distantFuture) < ($1.newestStart ?? .distantFuture) }
    }

    /// Climbs from each server through parent servers and launchers to the top of its tree.
    /// Returns each server's root PID, and the launchers found above each root.
    static func instanceTrees(servers: [DevServer], samples: [ProcessSample],
                              arguments: (ProcessSample) -> [String]?) -> (root: [Int32: Int32], launchers: [Int32: [ProcessSample]]) {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let serverPIDs = Set(servers.map(\.id))
        var launcherCache: [Int32: Bool] = [:]
        func isLauncher(_ sample: ProcessSample) -> Bool {
            if let known = launcherCache[sample.pid] { return known }
            let found = Self.isLauncher(name: sample.name, arguments: arguments(sample) ?? [])
            launcherCache[sample.pid] = found
            return found
        }

        var roots: [Int32: Int32] = [:]
        var launchers: [Int32: [ProcessSample]] = [:]
        for server in servers {
            var top = server.id
            var above: [ProcessSample] = []
            var seen: Set<Int32> = [top]
            while let parentPID = byPID[top]?.parentPID, parentPID > 1, seen.insert(parentPID).inserted,
                  let parent = byPID[parentPID] {
                if !serverPIDs.contains(parentPID) {
                    guard isLauncher(parent) else { break }
                    above.append(parent)
                }
                top = parentPID
            }
            roots[server.id] = top
            if !above.isEmpty { launchers[top] = above.reversed() }
        }
        return (roots, launchers)
    }

    /// Wrappers that only exist to run a server: killing the server alone would leave them (or restart it).
    static func isLauncher(name: String, arguments: [String]) -> Bool {
        let name = name.lowercased()
        if ["uv", "npm", "npx", "pnpm", "yarn", "bun", "honcho"].contains(name) { return true }
        return arguments.prefix(3).contains { $0 == "watchmedo" || $0.hasSuffix("/watchmedo") }
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
