import AppKit
import DevCleanCore
import SwiftUI

struct DevServersView: View {
    let monitor: SystemMonitor

    /// "Stop all stale" is two clicks: the first arms it, the second confirms.
    @State private var confirmStopAll = false

    var body: some View {
        let stale = monitor.staleProjects
        VStack(alignment: .leading, spacing: 10) {
            summary(stale: stale)

            if monitor.projects.isEmpty {
                Text("No dev servers running.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(sorted(monitor.projects, stale: stale)) { project in
                            ProjectRow(project: project,
                                       isStale: stale.contains(project),
                                       isStopping: monitor.stopping.contains(project.root)) {
                                Task { await monitor.stop([project]) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            if let summary = monitor.lastStopSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            ProtectedFoldersSection(monitor: monitor)
        }
    }

    private func summary(stale: [DevServerProject]) -> some View {
        let servers = monitor.projects.reduce(0) { $0 + $1.servers.count }
        let footprint = monitor.projects.reduce(0) { $0 + $1.footprint }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(servers) processes in \(monitor.projects.count) projects")
                    .font(.subheadline.weight(.semibold))
                Text("\(Format.memory(footprint)) · stale after \(monitor.staleAfterHours)h")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !stale.isEmpty {
                Button(confirmStopAll ? "Confirm: stop \(stale.count)" : "Stop \(stale.count) stale") {
                    if confirmStopAll {
                        confirmStopAll = false
                        Task { await monitor.stop(stale) }
                    } else {
                        confirmStopAll = true
                    }
                }
                .tint(confirmStopAll ? .red : nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .onChange(of: stale.count) { confirmStopAll = false }
    }

    /// Stale first, then unprotected, then protected; oldest first within each.
    private func sorted(_ projects: [DevServerProject], stale: [DevServerProject]) -> [DevServerProject] {
        func rank(_ project: DevServerProject) -> Int {
            stale.contains(project) ? 0 : project.isProtected ? 2 : 1
        }
        return projects.sorted {
            (rank($0), $0.newestStart ?? .distantFuture) < (rank($1), $1.newestStart ?? .distantFuture)
        }
    }
}

private struct ProjectRow: View {
    let project: DevServerProject
    let isStale: Bool
    let isStopping: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if project.isProtected {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(project.displayName())
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                }
                .help(project.root)

                Text(serverSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)

                HStack(spacing: 6) {
                    if let start = project.newestStart {
                        Text(Format.age(since: start))
                            .foregroundStyle(isStale ? .orange : .secondary)
                    }
                    Text(Format.memory(project.footprint)).foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
            Spacer()
            if isStopping {
                ProgressView().controlSize(.small)
            } else if !project.isProtected {
                Button("Stop", action: onStop)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(isStale ? 0.6 : 0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    /// "Django :18869 · Vite :19869 · esbuild", with repeats collapsed ("Celery ×5").
    private var serverSummary: String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for server in project.servers {
            if counts[server.label] == nil { order.append(server.label) }
            counts[server.label, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: " · ")
    }
}

private struct ProtectedFoldersSection: View {
    @Bindable var monitor: SystemMonitor
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Servers running in these folders are never stopped.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(monitor.protectedPaths, id: \.self) { path in
                    HStack {
                        Text(path).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            monitor.removeProtectedPath(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop protecting \(path)")
                    }
                }
                HStack {
                    Button("Add folder…", action: chooseFolder)
                    Spacer()
                    Stepper("Stale after \(monitor.staleAfterHours)h",
                            value: $monitor.staleAfterHours, in: 1...24 * 30, step: monitor.staleAfterHours >= 24 ? 24 : 1)
                        .font(.callout)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Protected folders (\(monitor.protectedPaths.count))").font(.subheadline.weight(.semibold))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Protect"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            monitor.addProtectedPath(url.path)
        }
    }
}
