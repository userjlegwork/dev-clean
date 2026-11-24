import DevCleanCore
import Foundation
import Observation

struct DiskUsageRow: Identifiable {
    var path: String
    var bytes: UInt64
    /// Change since the growth baseline, when there is one.
    var change: Int64?
    var kind: UsageKind
    var hint: String?

    var id: String { path }
}

/// Sizes the big folders now and then, keeps a short history on disk, and reports what grew fast.
/// Scans are slow, so they run in the background: a baseline shortly after launch, every few hours,
/// and early when free space drops (see `Growth.shouldScan`).
@MainActor
@Observable
final class DiskUsageModel {
    private(set) var history: [UsageSnapshot]
    private(set) var isScanning = false
    private(set) var growth: [FolderGrowth] = []
    private(set) var saveError: String?

    /// Receives the growth found by each scan (the monitor turns it into an insight).
    var onScan: (@MainActor ([FolderGrowth]) -> Void)? {
        didSet { onScan?(growth) }
    }

    private let launched = Date()
    private let url: URL

    var latest: UsageSnapshot? { history.last }

    init(url: URL = UsageHistory.standardURL) {
        self.url = url
        history = UsageHistory.trimmed(UsageHistory.load(from: url))
        // Growth found shortly before a relaunch still counts.
        if let latest, Date().timeIntervalSince(latest.date) < 6 * 3_600 {
            growth = Growth.detect(latest: latest, history: Array(history.dropLast()))
        }
    }

    /// Called after each poll; starts a scan when one is due.
    func check(diskFree: UInt64?) {
        guard !isScanning, Growth.shouldScan(now: Date(), free: diskFree, last: latest, launched: launched) else { return }
        Task { await scan() }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let snapshot = await Task.detached(priority: .utility) {
            await DiskUsage.scan(DiskUsage.folders()) {
                (try? SystemMetrics.disk(volume: URL(fileURLWithPath: "/")))?.free
            }
        }.value

        growth = Growth.detect(latest: snapshot, history: history)
        history = UsageHistory.trimmed(history + [snapshot])
        do {
            try UsageHistory.save(history, to: url)
            saveError = nil
        } catch {
            saveError = "Couldn't save size history: \(error.localizedDescription)"
        }
        onScan?(growth)
    }

    /// Biggest folders from the latest scan, with how much each changed since the growth baseline.
    func rows(limit: Int = 20) -> [DiskUsageRow] {
        guard let latest else { return [] }
        let base = Growth.baseline(for: latest, in: history)
        return latest.folders.sorted { $0.value > $1.value }.prefix(limit).map { path, bytes in
            DiskUsageRow(path: path, bytes: bytes,
                         change: base.map { Int64(bytes) - Int64($0.folders[path] ?? 0) },
                         kind: DiskUsage.kind(of: path), hint: DiskUsage.hint(for: path))
        }
    }

    /// When the change column is measured from.
    var baselineDate: Date? { latest.flatMap { Growth.baseline(for: $0, in: history)?.date } }
}
