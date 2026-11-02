import AppKit
import DevCleanCore
import SwiftUI

struct LargeFilesView: View {
    @Bindable var model: LargeFilesModel

    @State private var confirming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.files) { file in
                        LargeFileRow(file: file,
                                     blockedReason: blockedReason(file),
                                     isTrashing: model.trashing == file.id,
                                     isConfirming: confirming == file.id) {
                            if confirming == file.id {
                                confirming = nil
                                Task { await model.trash(file) }
                            } else {
                                confirming = file.id
                            }
                        }
                    }
                    if model.files.isEmpty && !model.isScanning && model.lastScan != nil {
                        Text("No files over \(model.minimumGB) GB.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 360)

            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Files go to the Trash, so nothing is lost until you empty it. Phone and iCloud folders, worktrees and simulators are left out.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .task { if model.lastScan == nil { await model.scan() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.files.count) files · \(Format.disk(model.files.reduce(0) { $0 + $1.size }))")
                    .font(.subheadline.weight(.semibold))
                Text(model.isScanning ? "Searching…" :
                        model.lastScan.map { "Searched \(Format.age(since: $0)) ago" } ?? "Not searched yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.minimumGB) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("≥ \($0) GB").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.minimumGB) { _, _ in Task { await model.scan() } }
            Button("Rescan") { Task { await model.scan() } }
                .disabled(model.isScanning)
        }
    }

    private func blockedReason(_ file: LargeFile) -> String? {
        if model.openFiles.contains(file.path) { return "Open in an app" }
        if file.path.hasPrefix(NSHomeDirectory() + "/Library/") { return "App data: remove it from the app that owns it" }
        return model.canTrash(file) ? nil : "Can't be moved to the Trash"
    }
}

private struct LargeFileRow: View {
    let file: LargeFile
    let blockedReason: String?
    let isTrashing: Bool
    let isConfirming: Bool
    let onTrash: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(file.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Format.disk(file.size)).font(.callout.monospacedDigit())
                }
                Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let blockedReason {
                    Label(blockedReason, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
                } else if isHiddenAppFolder {
                    Label("Inside a hidden app folder; check the app doesn't need it", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            if isTrashing {
                ProgressView().controlSize(.small)
            } else {
                Button(action: onTrash) {
                    if isConfirming { Text("Trash?") } else { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isConfirming ? .red : .primary)
                .disabled(blockedReason != nil)
                .help("Move to the Trash (click twice)")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var folder: String {
        let parent = ((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return [parent, file.modified.map { "modified \(Format.age(since: $0)) ago" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var isHiddenAppFolder: Bool {
        file.path.dropFirst(NSHomeDirectory().count + 1).hasPrefix(".")
    }
}
