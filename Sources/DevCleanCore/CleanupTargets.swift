import Foundation

public enum CleanupMethod: Sendable, Equatable {
    /// Delete everything inside the folder, keeping the folder itself.
    case deleteContents(String)
    /// Keep the newest `name-<number>` entry per name and delete the rest (Playwright's browser layout).
    case deleteOldVersions(String)
    /// Run the tool's own cleanup command. The first existing executable wins.
    case command(executables: [String], arguments: [String])
    /// `xcrun simctl` actions, sized from the actual devices they affect.
    case simulators(SimulatorAction)
}

public enum SimulatorAction: Sendable, Equatable {
    /// Devices whose runtime is no longer installed.
    case deleteUnavailable
    /// Reset every device to factory state (apps and data gone, devices kept).
    case eraseAll

    public var arguments: [String] {
        switch self {
        case .deleteUnavailable: ["simctl", "delete", "unavailable"]
        case .eraseAll: ["simctl", "erase", "all"]
        }
    }
}

public struct CleanupTarget: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// What happens and how it comes back, shown under the name.
    public var detail: String
    public var method: CleanupMethod
    /// Folders whose size is reported. For commands this is an upper bound.
    public var measuredPaths: [String]
    /// Don't run while a process with one of these exact names is alive.
    public var blockingProcesses: [String]
    /// …or while a process whose executable lives under one of these folders is alive.
    public var blockingExecutablePaths: [String]
    /// Pre-ticked in the UI. Only for caches that rebuild silently.
    public var selectedByDefault: Bool
    /// Deletions must stay strictly inside this folder (the user's home).
    public var allowedRoot: String

    public var isUpperBound: Bool {
        switch method {
        case .command, .simulators(.eraseAll): true
        default: false
        }
    }

    public init(id: String, name: String, detail: String, method: CleanupMethod, measuredPaths: [String],
                blockingProcesses: [String] = [], blockingExecutablePaths: [String] = [],
                selectedByDefault: Bool = false, allowedRoot: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.method = method
        self.measuredPaths = measuredPaths
        self.blockingProcesses = blockingProcesses
        self.blockingExecutablePaths = blockingExecutablePaths
        self.selectedByDefault = selectedByDefault
        self.allowedRoot = allowedRoot
    }
}

public enum CleanupCatalog {
    /// Targets that exist on this machine.
    public static func standard(home: String = NSHomeDirectory(),
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [CleanupTarget] {
        let all: [CleanupTarget] = [
            CleanupTarget(
                id: "uv", name: "uv cache",
                detail: "Python packages. Rebuilds on the next `uv sync`. Shared with project venvs, so it frees less than its size.",
                method: .command(executables: [home + "/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", home + "/.cargo/bin/uv"],
                                 // --force: long-running `uv run` processes hold the cache lock forever.
                                 arguments: ["cache", "clean", "--force"]),
                measuredPaths: [home + "/.cache/uv"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "npm", name: "npm cache",
                detail: "Downloaded npm packages. Re-downloaded when needed.",
                method: .deleteContents(home + "/.npm/_cacache"),
                measuredPaths: [home + "/.npm/_cacache"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "pnpm", name: "pnpm store (unused only)",
                detail: "Runs `pnpm store prune`, which removes only packages no project links to.",
                method: .command(executables: ["/opt/homebrew/bin/pnpm", home + "/Library/pnpm/pnpm", "/usr/local/bin/pnpm"],
                                 arguments: ["store", "prune"]),
                measuredPaths: [home + "/Library/pnpm/store"],
                blockingProcesses: ["pnpm"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "bun", name: "Bun cache",
                detail: "Downloaded Bun packages. Re-downloaded when needed.",
                method: .deleteContents(home + "/.bun/install/cache"),
                measuredPaths: [home + "/.bun/install/cache"],
                blockingProcesses: ["bun"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "pip", name: "pip cache",
                detail: "Downloaded Python wheels. Re-downloaded when needed.",
                method: .deleteContents(home + "/Library/Caches/pip"),
                measuredPaths: [home + "/Library/Caches/pip"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "homebrew", name: "Homebrew downloads",
                detail: "Cached bottle downloads. Installed packages are untouched.",
                method: .deleteContents(home + "/Library/Caches/Homebrew"),
                measuredPaths: [home + "/Library/Caches/Homebrew"],
                blockingProcesses: ["brew"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "derived-data", name: "Xcode DerivedData",
                detail: "Build products and indexes. Xcode rebuilds them on the next build.",
                method: .deleteContents(home + "/Library/Developer/Xcode/DerivedData"),
                measuredPaths: [home + "/Library/Developer/Xcode/DerivedData"],
                blockingProcesses: ["Xcode", "xcodebuild"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "simulator-caches", name: "Simulator caches",
                detail: "Shared simulator caches. Regenerated on the next simulator boot.",
                method: .deleteContents(home + "/Library/Developer/CoreSimulator/Caches"),
                measuredPaths: [home + "/Library/Developer/CoreSimulator/Caches"],
                blockingProcesses: ["Simulator", "launchd_sim"],
                allowedRoot: home),
            CleanupTarget(
                id: "simulators-unavailable", name: "Unavailable simulators",
                detail: "Devices whose iOS runtime is no longer installed. They can't boot anyway.",
                method: .simulators(.deleteUnavailable),
                measuredPaths: [home + "/Library/Developer/CoreSimulator/Devices"],
                blockingProcesses: ["Simulator", "launchd_sim"],
                selectedByDefault: true, allowedRoot: home),
            CleanupTarget(
                id: "simulators-erase", name: "Erase all simulator contents",
                detail: "Resets every simulator to factory state: installed apps and their data are removed, devices are kept.",
                method: .simulators(.eraseAll),
                measuredPaths: [home + "/Library/Developer/CoreSimulator/Devices"],
                blockingProcesses: ["Simulator", "launchd_sim"],
                allowedRoot: home),
            CleanupTarget(
                id: "playwright", name: "Old Playwright browsers",
                detail: "Keeps the newest build of each browser. Projects pinned to an older Playwright re-download on `playwright install`.",
                method: .deleteOldVersions(home + "/Library/Caches/ms-playwright"),
                measuredPaths: [home + "/Library/Caches/ms-playwright"],
                blockingExecutablePaths: [home + "/Library/Caches/ms-playwright"],
                allowedRoot: home),
        ]
        return all.filter { target in target.measuredPaths.contains(where: fileExists) }
    }
}
