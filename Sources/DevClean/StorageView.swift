import AppKit
import DevCleanCore
import SwiftUI

struct StorageView: View {
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
            .frame(maxHeight: 340)

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
