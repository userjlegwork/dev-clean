import AppKit
import DevCleanCore
import SwiftUI

struct WorktreesView: View {
    let monitor: SystemMonitor
    @Bindable var model: WorktreeModel

    @State private var confirmRemove = false

    private var staleAfter: TimeInterval { TimeInterval(monitor.staleAfterHours) * 3_600 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.rows) { row in
                        WorktreeRowView(row: row,
                                        isRemoving: model.removing == row.id,
                                        error: model.errors[row.id],
                                        isSelected: Binding(
                                            get: { model.selected.contains(row.id) },
                                            set: { on in
                                                if on { model.selected.insert(row.id) } else { model.selected.remove(row.id) }
                                                confirmRemove = false
                                            }))
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 340)

            if let summary = model.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Only clean, pushed worktrees with nothing running in them can be removed, via git worktree remove. Ignored files such as node_modules and .env go with them.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)

            actions
        }
        .task { if model.lastScan == nil { await rescan() } }
    }

    private func rescan() async {
        await model.scan(protectedPaths: monitor.protectedPaths, staleAfter: staleAfter)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.rows.count) worktrees · \(model.removableCount) removable")
                    .font(.subheadline.weight(.semibold))
                Text(model.isScanning ? "Checking… sizes take a minute" :
                        model.lastScan.map { "Checked \(Format.age(since: $0)) ago" } ?? "Not checked yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Add repository…") { addRepository() }
                ForEach(model.extraRepositories, id: \.self) { path in
                    Button("Stop checking \((path as NSString).abbreviatingWithTildeInPath)") {
                        model.extraRepositories.removeAll { $0 == path }
                    }
                }
            } label: { Image(systemName: "folder.badge.plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Codex worktrees are found automatically. Add other repositories whose worktrees should be checked.")
            Button("Rescan") { Task { await rescan() } }
                .disabled(model.isScanning || model.isRemoving)
        }
    }

    private var actions: some View {
        HStack {
            Button("Log") { NSWorkspace.shared.open(model.log.url) }
                .disabled(!FileManager.default.fileExists(atPath: model.log.url.path))
            Spacer()
            if model.isRemoving {
                ProgressView().controlSize(.small)
                Text("Removing…").font(.callout)
            } else {
                Button(confirmRemove
                       ? "Confirm: remove \(model.selected.count)"
                       : "Remove \(model.selected.count) (\(Format.disk(model.selectedSize)))") {
                    if confirmRemove {
                        confirmRemove = false
                        Task {
                            await model.remove(protectedPaths: monitor.protectedPaths, staleAfter: staleAfter) { [monitor] in
                                monitor.liveDiskFree()
                            }
                            await monitor.refresh()
                        }
                    } else {
                        confirmRemove = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(confirmRemove ? .red : nil)
                .disabled(model.selected.isEmpty || model.isScanning)
            }
        }
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a repository's main checkout"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !model.extraRepositories.contains(url.path) { model.extraRepositories.append(url.path) }
        Task { await rescan() }
    }
}

private struct WorktreeRowView: View {
    let row: WorktreeRow
    let isRemoving: Bool
    let error: String?
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!row.isRemovable)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.worktree.displayName()).font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if isRemoving {
                        ProgressView().controlSize(.small)
                    } else if let size = row.size {
                        Text(Format.disk(size)).font(.callout.monospacedDigit())
                    } else if !row.worktree.isPrunable {
                        Text("…").foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)

                if row.status == nil {
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                } else if !row.blockers.isEmpty {
                    Label(row.blockers.joined(separator: " · "), systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !row.worktree.isPrunable {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.worktree.path)])
                } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var detail: String {
        if row.worktree.isPrunable { return "Folder already gone · removes git's leftover record" }
        let branch = row.worktree.branch ?? "detached at \(row.worktree.head?.prefix(7) ?? "?")"
        let activity = row.status?.lastActivity.map { "last used \(Format.age(since: $0)) ago" }
        return [branch, activity].compactMap { $0 }.joined(separator: " · ")
    }
}
