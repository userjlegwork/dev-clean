import DevCleanCore
import Foundation
import Observation

/// Finds big files in home and moves the chosen ones to the Trash, one at a time.
@MainActor
@Observable
final class LargeFilesModel {
    private(set) var files: [LargeFile] = []
    /// Files some process has open; they can't be trashed.
    private(set) var openFiles: Set<String> = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var trashing: String?
    private(set) var message: String?
    private(set) var trashedBytes: UInt64 = 0

    let log = CleanupLog.standard

    var minimumGB: Int {
        didSet { UserDefaults.standard.set(minimumGB, forKey: "largeFileMinimumGB") }
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "largeFileMinimumGB")
        minimumGB = saved > 0 ? saved : 1
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let minimum = UInt64(minimumGB) * 1_000_000_000
        files = await LargeFileFinder.find(minimumSize: minimum)
        openFiles = await LargeFileFinder.openPaths(files.map(\.path))
        lastScan = Date()
    }

    func canTrash(_ file: LargeFile) -> Bool {
        !openFiles.contains(file.path) && LargeFileFinder.canTrash(file.path)
    }

    func trash(_ file: LargeFile) async {
        guard trashing == nil else { return }
        trashing = file.id
        defer { trashing = nil }
        do {
            try await LargeFileFinder.moveToTrash(file.path)
            files.removeAll { $0.id == file.id }
            trashedBytes += file.size
            message = "Moved \(file.name) to the Trash. Empty the Trash to get \(Format.disk(trashedBytes)) back."
            log.append(.init(date: Date(), target: "Large file", action: "Move to Trash \(file.path)", estimatedBytes: file.size,
                             result: CleanupResult(targetID: "large-file", succeeded: true, message: "Moved to Trash",
                                                   removedItems: 1, freedBytes: 0)))
        } catch {
            if case CleanupError.inUse = error { openFiles.insert(file.path) }
            message = String(describing: error)
        }
    }
}
