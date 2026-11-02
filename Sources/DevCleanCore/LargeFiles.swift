import Foundation

public struct LargeFile: Sendable, Identifiable, Equatable {
    public var path: String
    /// Allocated bytes, so sparse disk images count what they really use.
    public var size: UInt64
    public var modified: Date?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum LargeFileFinder {
    public static let defaultMinimumSize: UInt64 = 1_000_000_000

    /// Spotlight for the indexed part of home, plus a walk of dot-folders, which Spotlight skips
    /// (~/.android emulators, model caches). Sorted largest first.
    public static func find(home: String = NSHomeDirectory(), minimumSize: UInt64 = defaultMinimumSize) async -> [LargeFile] {
        let indexed = await spotlight(home: home, minimumSize: minimumSize)
        let hidden = walk(hiddenFolders(home: home), minimumSize: minimumSize, home: home)
        var seen = Set<String>()
        return (indexed + hidden)
            .filter { !isExcluded($0, home: home) && seen.insert($0).inserted }
            .compactMap { file(at: $0, minimumSize: minimumSize) }
            .sorted { $0.size > $1.size }
    }

    static func spotlight(home: String, minimumSize: UInt64) async -> [String] {
        let output = await CommandRunner.run("/usr/bin/mdfind", ["-onlyin", home, "kMDItemFSSize >= \(minimumSize)"],
                                             timeout: .seconds(60))
        guard output.status == 0 else { return [] }
        return output.output.split(whereSeparator: \.isNewline).map(String.init)
    }

    static func hiddenFolders(home: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0.hasPrefix(".") && $0 != ".Trash" }
            .map { home + "/" + $0 }
    }

    /// Folders that are huge in file count but hold nothing worth hand-picking; skipping them keeps the walk to seconds.
    static let skippedFolderNames: Set<String> = ["node_modules", ".git", ".venv", "venv", "__pycache__"]

    static func walk(_ roots: [String], minimumSize: UInt64, home: String) -> [String] {
        var found: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [],
                errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                // The enumerator can report /var as /private/var.
                let path = DevServerRules.normalize(url.path)
                if values.isDirectory == true {
                    if skippedFolderNames.contains(url.lastPathComponent) || isExcluded(path, home: home) {
                        enumerator.skipDescendants()
                    }
                } else if values.isRegularFile == true,
                          UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) >= minimumSize {
                    found.append(path)
                }
            }
        }
        return found
    }

    /// Places that aren't really this disk's files or that other tabs already handle.
    static func excludedFolders(home: String) -> [String] {
        [
            home + "/Library/CloudStorage",       // phone and cloud mounts (MacDroid, Dropbox…)
            home + "/Library/Mobile Documents",   // iCloud Drive
            home + "/.Trash",
            home + "/.codex/worktrees",           // Worktrees section
            home + "/Library/Developer/CoreSimulator", // Caches section
        ]
    }

    static func isExcluded(_ path: String, home: String) -> Bool {
        excludedFolders(home: home).contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func file(at path: String, minimumSize: UInt64) -> LargeFile? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              values.isRegularFile == true else { return nil } // Spotlight also reports bundles; their big files are found inside
        let size = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        guard size >= minimumSize else { return nil }
        return LargeFile(path: path, size: size, modified: values.contentModificationDate)
    }

    // MARK: - Trash

    /// Files under ~/Library belong to apps (Docker's disk, Android SDK images, VMs); remove those from the app instead.
    public static func canTrash(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(home + "/"), !standardized.hasPrefix(home + "/Library/"),
              !isExcluded(standardized, home: home) else { return false }
        let values = try? URL(fileURLWithPath: standardized).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    /// Which of `paths` some process has open (a live database, a running VM's disk). One lsof call for all of them.
    public static func openPaths(_ paths: [String]) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        // Exit status is 1 when none are open, so only the output matters.
        let output = await CommandRunner.run("/usr/sbin/lsof", ["-F", "n", "--"] + paths, timeout: .seconds(30))
        // lsof prints real paths (/private/var/…); map them back to what the caller passed.
        let byRealPath = Dictionary(paths.map { (realPath($0), $0) }, uniquingKeysWith: { first, _ in first })
        return Set(output.output.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("n") }
            .compactMap { byRealPath[String($0.dropFirst())] })
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Moves to the Trash (recoverable). Space comes back only once the Trash is emptied.
    public static func moveToTrash(_ path: String, home: String = NSHomeDirectory()) async throws {
        guard canTrash(path, home: home) else { throw CleanupError.unsafePath(path) }
        guard await openPaths([path]).isEmpty else { throw CleanupError.inUse(path) }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}
