import Foundation

public enum DirectorySizer {
    /// Allocated bytes under `path`, like `du`. Symlinks aren't followed. Counts APFS clones at full size,
    /// so it can overstate what deleting would free.
    public static func allocatedSize(of path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }

        var total: UInt64 = 0
        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited % 10_000 == 0, Task.isCancelled { break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
