import Foundation

public struct CleanupPlan: Sendable, Equatable {
    public var targetID: String
    /// Human-readable steps, e.g. "Delete 3 items in ~/.npm/_cacache".
    public var actions: [String]
    /// Running processes that must be quit first. Non-empty means the target won't run.
    public var blockedBy: [String]
    public var error: String?

    public var canRun: Bool { blockedBy.isEmpty && error == nil }
}

public struct CleanupResult: Sendable, Equatable, Codable {
    public var targetID: String
    public var succeeded: Bool
    public var message: String
    public var removedItems: Int
    /// Free-space difference measured around this target. Can be less than its size (APFS clones, hard links).
    public var freedBytes: Int64

    public init(targetID: String, succeeded: Bool, message: String, removedItems: Int, freedBytes: Int64) {
        self.targetID = targetID
        self.succeeded = succeeded
        self.message = message
        self.removedItems = removedItems
        self.freedBytes = freedBytes
    }
}

public enum CleanupError: Error, CustomStringConvertible, Equatable {
    case unsafePath(String)
    case missingExecutable(String)
    case blocked([String])
    case inUse(String)

    public var description: String {
        switch self {
        case .unsafePath(let path): "Refusing to delete inside \(path)"
        case .missingExecutable(let name): "\(name) isn't installed"
        case .blocked(let names): "Quit \(names.joined(separator: ", ")) first"
        case .inUse(let path): "\((path as NSString).lastPathComponent) is open in an app"
        }
    }
}

/// Snapshot of running processes used to decide whether a target is blocked.
public struct RunningProcesses: Sendable {
    public var names: Set<String>
    public var executablePaths: [String]

    public init(names: Set<String>, executablePaths: [String]) {
        self.names = names
        self.executablePaths = executablePaths
    }

    public init(_ samples: [ProcessSample]) {
        self.init(names: Set(samples.map(\.name)), executablePaths: samples.compactMap(\.executablePath))
    }

    public static func current() -> RunningProcesses { RunningProcesses(ProcessScanner.scan()) }
}

public enum CleanupRunner {
    // MARK: - Preview

    public static func plan(_ target: CleanupTarget, running: RunningProcesses) -> CleanupPlan {
        var plan = CleanupPlan(targetID: target.id, actions: [], blockedBy: blockers(for: target, running: running))
        do {
            switch target.method {
            case .deleteContents(let directory):
                let items = try removableItems(target)
                plan.actions = ["Delete \(items.count) item\(items.count == 1 ? "" : "s") in \(abbreviate(directory))"]
            case .deleteOldVersions(let directory):
                let items = try removableItems(target)
                plan.actions = items.isEmpty
                    ? ["Nothing to remove in \(abbreviate(directory)): only the newest versions are installed"]
                    : items.map { "Delete \(abbreviate(directory))/\($0.lastPathComponent)" }
            case .command(let executables, let arguments):
                let executable = try resolveExecutable(executables)
                plan.actions = ["Run \(([abbreviate(executable)] + arguments).joined(separator: " "))"]
            case .simulators(let action):
                _ = try resolveExecutable([Simulators.xcrun])
                let devices = affectedSimulators(action)
                plan.actions = devices.isEmpty
                    ? ["Nothing to do: no matching simulators"]
                    : ["Run xcrun \(action.arguments.joined(separator: " ")) (\(devices.count) device\(devices.count == 1 ? "" : "s"))"]
                        + devices.prefix(5).map { "\($0.name) · \($0.runtime)" }
            }
        } catch {
            plan.error = String(describing: error)
        }
        return plan
    }

    public static func blockers(for target: CleanupTarget, running: RunningProcesses) -> [String] {
        var found = target.blockingProcesses.filter(running.names.contains)
        for folder in target.blockingExecutablePaths
        where running.executablePaths.contains(where: { $0.hasPrefix(folder + "/") }) {
            found.append("processes in \(abbreviate(folder))")
        }
        return found
    }

    /// Size that cleaning would target. For commands this is the whole measured folder (an upper bound).
    public static func estimate(_ target: CleanupTarget) -> UInt64 {
        switch target.method {
        case .deleteContents, .command:
            return target.measuredPaths.reduce(0) { $0 + DirectorySizer.allocatedSize(of: $1) }
        case .deleteOldVersions:
            let items = (try? removableItems(target)) ?? []
            return items.reduce(0) { $0 + DirectorySizer.allocatedSize(of: $1.path) }
        case .simulators(let action):
            return affectedSimulators(action).reduce(0) {
                $0 + DirectorySizer.allocatedSize(of: Simulators.deviceFolder($1, home: target.allowedRoot))
            }
        }
    }

    static func affectedSimulators(_ action: SimulatorAction) -> [SimulatorDevice] {
        let devices = Simulators.devices()
        switch action {
        case .deleteUnavailable: return devices.filter { !$0.isAvailable }
        case .eraseAll: return devices
        }
    }

    // MARK: - Run

    /// Runs one target. Re-checks blockers and paths right before acting.
    public static func run(_ target: CleanupTarget, running: RunningProcesses,
                           commandTimeout: Duration = .seconds(600)) async -> (removedItems: Int, error: String?) {
        let blocked = blockers(for: target, running: running)
        guard blocked.isEmpty else { return (0, CleanupError.blocked(blocked).description) }

        switch target.method {
        case .deleteContents, .deleteOldVersions:
            do {
                let items = try removableItems(target)
                var removed = 0
                var failures: [String] = []
                for item in items {
                    do {
                        try FileManager.default.removeItem(at: item)
                        removed += 1
                    } catch {
                        failures.append(item.lastPathComponent)
                    }
                }
                let error = failures.isEmpty ? nil : "Couldn't remove \(failures.count) item(s): \(failures.prefix(3).joined(separator: ", "))"
                return (removed, error)
            } catch {
                return (0, String(describing: error))
            }

        case .simulators(let action):
            guard !affectedSimulators(action).isEmpty else { return (0, nil) }
            let output = await CommandRunner.run(Simulators.xcrun, action.arguments, timeout: commandTimeout)
            if output.timedOut { return (0, "Timed out: \(output.tail)") }
            return output.status == 0 ? (0, nil) : (0, "Exited \(output.status): \(output.tail)")

        case .command(let executables, let arguments):
            do {
                let executable = try resolveExecutable(executables)
                let output = await CommandRunner.run(executable, arguments, timeout: commandTimeout)
                if output.timedOut { return (0, "Timed out: \(output.tail)") }
                return output.status == 0 ? (0, nil) : (0, "Exited \(output.status): \(output.tail)")
            } catch {
                return (0, String(describing: error))
            }
        }
    }

    // MARK: - Paths

    /// What a delete method would remove. Throws if the folder isn't safely inside `allowedRoot`.
    public static func removableItems(_ target: CleanupTarget) throws -> [URL] {
        switch target.method {
        case .deleteContents(let directory):
            return try children(of: directory, allowedRoot: target.allowedRoot)
        case .deleteOldVersions(let directory):
            let children = try children(of: directory, allowedRoot: target.allowedRoot)
            let old = Set(oldVersions(children.map(\.lastPathComponent)))
            return children.filter { old.contains($0.lastPathComponent) }
        case .command, .simulators:
            return []
        }
    }

    /// From `name-<number>` entries, everything except the highest number per name. Other entries are kept.
    public static func oldVersions(_ names: [String]) -> [String] {
        var newest: [String: Int] = [:]
        var parsed: [(name: String, base: String, version: Int)] = []
        for name in names where !name.hasPrefix(".") {
            guard let dash = name.lastIndex(of: "-"), let version = Int(name[name.index(after: dash)...]) else { continue }
            let base = String(name[..<dash])
            parsed.append((name, base, version))
            newest[base] = max(newest[base] ?? version, version)
        }
        return parsed.filter { $0.version < newest[$0.base]! }.map(\.name).sorted()
    }

    /// A folder is deletable only if it's a real directory (not a symlink) at least two levels below `allowedRoot`,
    /// so a bad config can never empty the home folder or something like ~/Library.
    public static func isSafeDirectory(_ directory: String, allowedRoot: String) -> Bool {
        let path = (directory as NSString).standardizingPath
        let root = (allowedRoot as NSString).standardizingPath
        guard path.hasPrefix("/"), root.count > 1, path.hasPrefix(root + "/") else { return false }
        let depth = path.dropFirst(root.count + 1).split(separator: "/").count
        guard depth >= 2 else { return false }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        return true
    }

    static func children(of directory: String, allowedRoot: String) throws -> [URL] {
        guard isSafeDirectory(directory, allowedRoot: allowedRoot) else { throw CleanupError.unsafePath(directory) }
        return try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil, options: [])
    }

    static func resolveExecutable(_ candidates: [String]) throws -> String {
        guard let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CleanupError.missingExecutable((candidates.first.map { ($0 as NSString).lastPathComponent }) ?? "tool")
        }
        return found
    }

    static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
