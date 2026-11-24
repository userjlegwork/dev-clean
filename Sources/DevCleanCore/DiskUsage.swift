import Foundation

/// Sizes of the folders that usually hold most of a dev Mac's disk, at one moment.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var date: Date
    /// Free disk space when the scan finished.
    public var free: UInt64
    /// Allocated bytes per folder path.
    public var folders: [String: UInt64]

    public init(date: Date, free: UInt64, folders: [String: UInt64]) {
        self.date = date
        self.free = free
        self.folders = folders
    }

    public var measured: UInt64 { folders.values.reduce(0, +) }
}

/// What deleting a folder means, for the label next to it.
public enum UsageKind: Sendable, Equatable {
    /// Caches and logs: the tool rebuilds them.
    case rebuilds
    /// Documents, downloads, backups: only the user knows.
    case yours
    /// An app's own data: remove it from inside that app.
    case app

    public var label: String {
        switch self {
        case .rebuilds: "Rebuilds itself"
        case .yours: "Your files"
        case .app: "Managed by an app"
        }
    }
}

/// A folder that grew between two scans.
public struct FolderGrowth: Sendable, Equatable {
    public var path: String
    public var bytes: UInt64
    public var interval: TimeInterval

    public init(path: String, bytes: UInt64, interval: TimeInterval) {
        self.path = path
        self.bytes = bytes
        self.interval = interval
    }
}

public enum DiskUsage {
    /// ~/Library folders listed one level deeper, since their totals alone don't point at anything.
    static let expandedLibraryFolders = ["Application Support", "Caches"]
    /// Never opened: other apps' sandboxes (macOS asks the user before an app reads them, even to
    /// size them) and cloud or phone mounts, whose files aren't really on this disk.
    static let skippedLibraryFolders: Set<String> = [
        "Containers", "Group Containers", "Daemon Containers", "Application Scripts",
        "CloudStorage", "Mobile Documents",
    ]
    /// Packages that need their own privacy permission to look inside.
    static let skippedPackageExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary"]

    /// The folders a scan sizes: everything in home except ~/Library, which is split up instead,
    /// plus /Applications and Homebrew.
    public static func folders(home: String = NSHomeDirectory(), extra: [String] = ["/Applications", "/opt/homebrew"]) -> [String] {
        let fm = FileManager.default
        func children(_ path: String, skipping: Set<String> = []) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
                .filter { !skipping.contains($0) }
                .map { "\(path)/\($0)" }
                .filter(isRealDirectory)
        }
        let library = home + "/Library"
        var paths = children(home, skipping: ["Library"])
        paths += children(library, skipping: skippedLibraryFolders.union(expandedLibraryFolders))
        for name in expandedLibraryFolders { paths += children("\(library)/\(name)") }
        paths += extra.filter(isRealDirectory)
        return paths
    }

    /// Sizes `folders`, `width` at a time. Slow (minutes for a full home): run it off the main actor.
    public static func scan(_ folders: [String], width: Int = 4, free: @Sendable () -> UInt64?) async -> UsageSnapshot {
        var sizes: [String: UInt64] = [:]
        await withTaskGroup(of: (String, UInt64).self) { group in
            var pending = folders[...]
            for _ in 0..<width {
                guard let path = pending.popFirst() else { break }
                group.addTask(priority: .utility) { (path, size(of: path)) }
            }
            for await (path, bytes) in group {
                sizes[path] = bytes
                if let path = pending.popFirst() { group.addTask(priority: .utility) { (path, size(of: path)) } }
            }
        }
        return UsageSnapshot(date: Date(), free: free() ?? 0, folders: sizes)
    }

    static func size(of path: String) -> UInt64 {
        DirectorySizer.allocatedSize(of: path) { url in
            skippedPackageExtensions.contains(url.pathExtension.lowercased())
        }
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Labels

    public static func kind(of path: String, home: String = NSHomeDirectory()) -> UsageKind {
        let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let rebuilds = ["Library/Caches", "Library/Logs", ".cache", ".npm", ".yarn", "Library/pnpm", ".gradle", ".bun"]
        if rebuilds.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return .rebuilds }
        if relative == ".Trash" { return .yours }
        let outsideHome = !path.hasPrefix(home + "/")
        if outsideHome || relative.hasPrefix("Library/") || relative.hasPrefix(".") { return .app }
        return .yours
    }

    /// Where to deal with the biggest usual suspects.
    public static func hint(for path: String, home: String = NSHomeDirectory()) -> String? {
        let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let hints: [String: String] = [
            ".codex": "Codex worktrees and transcripts; idle worktrees go in the Worktrees section",
            ".Trash": "Empty the Trash to get this back",
            ".android": "Android emulators; delete unused ones in Android Studio's Device Manager",
            "Library/Android": "Android SDK; remove old system images in Android Studio's SDK Manager",
            "Library/Developer": "Xcode simulators and caches; see the Caches section",
            ".docker": "Docker settings; its disk lives in Docker Desktop (Settings → Resources)",
            "Library/Application Support/Claude": "Claude's VM bundles download again when needed",
            "Downloads": "Old installers and archives are usually safe to delete",
            "/opt/homebrew": "Installed packages; `brew autoremove` drops unused dependencies",
        ]
        return hints[relative]
    }

    /// "~/Library/Caches/Google" style.
    public static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

public enum UsageHistory {
    /// Snapshots older than this are dropped; growth is only compared within a day anyway.
    public static let keepFor: TimeInterval = 14 * 86_400
    public static let maxSnapshots = 60

    public static func trimmed(_ history: [UsageSnapshot], now: Date = Date()) -> [UsageSnapshot] {
        Array(history.filter { now.timeIntervalSince($0.date) < keepFor }
            .sorted { $0.date < $1.date }
            .suffix(maxSnapshots))
    }

    public static func load(from url: URL) -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UsageSnapshot].self, from: data)) ?? []
    }

    public static func save(_ history: [UsageSnapshot], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(history).write(to: url, options: .atomic)
    }

    public static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevClean/usage-history.json")
    }
}

public enum Growth {
    /// Growth below this isn't worth a warning.
    public static let minimum: UInt64 = 3_000_000_000
    /// Scans closer together than this say little; further apart, growth is old news.
    public static let minInterval: TimeInterval = 15 * 60
    public static let maxInterval: TimeInterval = 24 * 3_600

    /// The snapshot to compare `latest` with: the newest one at least `minInterval` older, within `maxInterval`.
    public static func baseline(for latest: UsageSnapshot, in history: [UsageSnapshot]) -> UsageSnapshot? {
        history.filter {
            let age = latest.date.timeIntervalSince($0.date)
            return age >= minInterval && age <= maxInterval
        }.max { $0.date < $1.date }
    }

    /// Folders that grew by at least `minimum` since the baseline, biggest first. A folder only in
    /// `latest` (new since the baseline) counts from zero.
    public static func detect(latest: UsageSnapshot, history: [UsageSnapshot], minimum: UInt64 = minimum) -> [FolderGrowth] {
        guard let base = baseline(for: latest, in: history) else { return [] }
        let interval = latest.date.timeIntervalSince(base.date)
        return latest.folders.compactMap { path, bytes in
            let before = base.folders[path] ?? 0
            guard bytes > before, bytes - before >= minimum else { return nil }
            return FolderGrowth(path: path, bytes: bytes - before, interval: interval)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Whether to size everything again now. Scans are slow, so: a first baseline shortly after launch,
    /// a refresh every `refreshEvery`, and an early one when free space fell by `minimum` since the last.
    public static func shouldScan(now: Date, free: UInt64?, last: UsageSnapshot?, launched: Date,
                                  refreshEvery: TimeInterval = 6 * 3_600) -> Bool {
        guard let last else { return now.timeIntervalSince(launched) >= 120 }
        let age = now.timeIntervalSince(last.date)
        if age >= refreshEvery { return true }
        guard age >= minInterval, let free, last.free > free else { return false }
        return last.free - free >= minimum
    }

    /// "3h", "45m": how long the growth took.
    public static func duration(_ interval: TimeInterval) -> String {
        Format.age(since: Date(timeIntervalSinceNow: -interval))
    }
}
