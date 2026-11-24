import AppKit
import DevCleanCore
import SwiftUI

struct StorageView: View {
    let monitor: SystemMonitor
    let storage: StorageModel

    private enum Section: String { case disk, caches, worktrees, largeFiles }

    @AppStorage("storageSection") private var section = Section.caches

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $section) {
                Text("Disk").tag(Section.disk)
                Text("Caches").tag(Section.caches)
                Text("Worktrees").tag(Section.worktrees)
                Text("Large files").tag(Section.largeFiles)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch section {
            case .disk: DiskUsageView(monitor: monitor, model: storage.diskUsage)
            case .caches: CachesView(monitor: monitor, storage: storage)
            case .worktrees: WorktreesView(monitor: monitor, model: storage.worktrees)
            case .largeFiles: LargeFilesView(model: storage.largeFiles)
            }
        }
    }
}

private struct CachesView: View {
    let monitor: SystemMonitor
    @Bindable var storage: StorageModel

    @State private var showPreview = false
    @State private var confirmClean = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(storage.targets) { target in
                        TargetRow(target: target,
                                  size: storage.sizes[target.id],
                                  isSizing: storage.sizing.contains(target.id),
                                  plan: storage.plans[target.id],
                                  showPreview: showPreview,
                                  result: storage.results.first { $0.targetID == target.id },
                                  isRunning: storage.runningTarget == target.id,
                                  isSelected: Binding(
                                      get: { storage.selected.contains(target.id) },
                                      set: { on in
                                          if on { storage.selected.insert(target.id) } else { storage.selected.remove(target.id) }
                                          confirmClean = false
                                      }))
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 340)

            if let summary = storage.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .task { if storage.lastScan == nil { await storage.scan() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let disk = monitor.system?.disk {
                    Text("\(Format.disk(disk.free)) free of \(Format.disk(disk.total))")
                        .font(.subheadline.weight(.semibold))
                }
                Text(storage.sizing.isEmpty
                     ? storage.lastScan.map { "Sized \(Format.age(since: $0)) ago" } ?? "Not sized yet"
                     : "Measuring… big caches take a minute")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rescan") { Task { await storage.scan() } }
                .disabled(!storage.sizing.isEmpty || storage.isRunning)
        }
    }

    private var actions: some View {
        HStack {
            Toggle("Preview", isOn: $showPreview)
                .toggleStyle(.checkbox)
                .onChange(of: showPreview) { _, on in if on { storage.refreshPlans() } }
                .help("Show exactly what each selected item will do, without doing it")
            Button("Log") { NSWorkspace.shared.open(storage.log.url) }
                .disabled(!FileManager.default.fileExists(atPath: storage.log.url.path))
            Spacer()
            if storage.isRunning {
                ProgressView().controlSize(.small)
                Text("Cleaning…").font(.callout)
            } else {
                Button(confirmClean
                       ? "Confirm: clean \(storage.selected.count)"
                       : "Clean \(storage.selected.count) (\(Format.disk(storage.selectedEstimate)))") {
                    if confirmClean {
                        confirmClean = false
                        Task {
                            await storage.clean { [monitor] in monitor.liveDiskFree() }
                            await monitor.refresh()
                        }
                    } else {
                        storage.refreshPlans()
                        confirmClean = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(confirmClean ? .red : nil)
                .disabled(storage.selected.isEmpty || !storage.sizing.isEmpty)
            }
        }
    }
}

private struct TargetRow: View {
    let target: CleanupTarget
    let size: UInt64?
    let isSizing: Bool
    let plan: CleanupPlan?
    let showPreview: Bool
    let result: CleanupResult?
    let isRunning: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(target.name).font(.callout.weight(.medium))
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else if isSizing {
                        Text("…").foregroundStyle(.secondary)
                    } else if let size {
                        Text((target.isUpperBound ? "up to " : "") + Format.disk(size))
                            .font(.callout.monospacedDigit())
                    }
                }
                Text(target.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let plan, !plan.blockedBy.isEmpty {
                    Label("Quit \(plan.blockedBy.joined(separator: ", ")) first", systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = plan?.error {
                    Label(error, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
                }
                if showPreview, isSelected, let plan {
                    ForEach(plan.actions, id: \.self) { action in
                        Text("→ " + action).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                if let result {
                    Label(result.succeeded ? "Freed \(Format.disk(UInt64(result.freedBytes)))" : result.message,
                          systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(result.succeeded ? .green : .orange)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Where the disk went: the biggest folders, what each one is, and what grew since the last scans.
private struct DiskUsageView: View {
    let monitor: SystemMonitor
    let model: DiskUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !model.growth.isEmpty {
                Label(model.growth.prefix(3).map {
                    "\(DiskUsage.displayPath($0.path)) +\(Format.disk($0.bytes)) in \(Growth.duration($0.interval))"
                }.joined(separator: " · "), systemImage: "arrow.up.right")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.rows()) { row in DiskUsageRowView(row: row) }
                    if let unmeasured { unmeasuredRow(unmeasured) }
                }
            }
            .frame(minHeight: 260, maxHeight: 340)

            if let error = model.saveError {
                Label(error, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
            }
            Text(footnote)
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let disk = monitor.system?.disk {
                    Text("\(Format.disk(disk.free)) free of \(Format.disk(disk.total))")
                        .font(.subheadline.weight(.semibold))
                }
                Text(model.isScanning ? "Measuring… a full scan takes a few minutes"
                     : model.latest.map { "Measured \(Format.age(since: $0.date)) ago" } ?? "Not measured yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning { ProgressView().controlSize(.small) }
            Button("Rescan") { Task { await model.scan() } }
                .disabled(model.isScanning)
        }
    }

    /// Used space the scan doesn't reach: macOS, swap, other apps' sandboxes (Docker's disk), other users.
    private var unmeasured: UInt64? {
        guard let latest = model.latest, let disk = monitor.system?.disk else { return nil }
        let used = disk.total > disk.free ? disk.total - disk.free : 0
        return used > latest.measured ? used - latest.measured : nil
    }

    private func unmeasuredRow(_ bytes: UInt64) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Everything else").font(.callout.weight(.medium))
                Text("macOS, swap, other apps' sandboxes (Docker's disk, Mail…) and folders outside your home. Not opened, so macOS doesn't ask for permission.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(Format.disk(bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footnote: String {
        var text = "Your home folder, ~/Library split by app, /Applications and Homebrew. Rescanned every 6 hours and when free space drops by 3 GB."
        if let base = model.baselineDate { text += " Changes are since \(Format.age(since: base)) ago." }
        return text
    }
}

private struct DiskUsageRowView: View {
    let row: DiskUsageRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(DiskUsage.displayPath(row.path)).font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let change = row.change, abs(change) >= 100_000_000 {
                        Text((change > 0 ? "+" : "−") + Format.disk(UInt64(abs(change))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(change >= Int64(Growth.minimum) ? .orange : .secondary)
                    }
                    Text(Format.disk(row.bytes)).font(.callout.monospacedDigit())
                }
                Text(([row.kind.label] + [row.hint].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(row.kind == .rebuilds ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
