import AppKit
import DevCleanCore
import ServiceManagement
import SwiftUI

struct DashboardView: View {
    let monitor: SystemMonitor

    private enum Tab { case overview, devServers }

    @State private var tab = Tab.overview
    @State private var showProcesses = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("", selection: $tab) {
                Text("Overview").tag(Tab.overview)
                Text(monitor.staleProjects.isEmpty ? "Dev servers" : "Dev servers (\(monitor.staleProjects.count) stale)")
                    .tag(Tab.devServers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let error = monitor.lastError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }

            switch tab {
            case .overview: overview
            case .devServers: DevServersView(monitor: monitor)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder
    private var overview: some View {
        if !monitor.insights.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(monitor.insights) { insight in
                    InsightRow(insight: insight)
                        .contentShape(Rectangle())
                        .onTapGesture { if insight.id == "stale-servers" { tab = .devServers } }
                }
            }
        }

        if let system = monitor.system {
            gauges(system)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }

        Divider()
        topConsumers
    }

    private var header: some View {
        HStack {
            Text("DevClean").font(.headline)
            Spacer()
            if let system = monitor.system {
                Text("Up \(Format.age(since: system.bootTime))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Last restart: \(system.bootTime.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    @ViewBuilder
    private func gauges(_ system: SystemSnapshot) -> some View {
        let memory = system.memory
        MetricGauge(
            title: "Memory",
            value: "\(Format.memory(memory.used)) of \(Format.memory(memory.total))",
            fraction: Double(memory.used) / Double(max(memory.total, 1)),
            detail: "Compressed \(Format.memory(memory.compressed)) · \(memory.freePercent)% free · pressure \(memory.pressure.label)",
            severity: memory.pressure.severity)

        let swap = system.swap
        MetricGauge(
            title: "Swap",
            value: "\(Format.memory(swap.used)) of \(Format.memory(swap.total))",
            fraction: swap.usedFraction,
            detail: "Grows on disk when RAM runs out. Only a restart fully clears it.",
            severity: severity(for: "swap"))

        let disk = system.disk
        MetricGauge(
            title: "Disk",
            value: "\(Format.disk(disk.free)) free of \(Format.disk(disk.total))",
            fraction: disk.usedFraction,
            detail: "Finder counts \(Format.disk(disk.availableForImportantUsage)) available, including purgeable space.",
            severity: severity(for: "disk"))
    }

    private func severity(for id: String) -> Severity {
        monitor.insights.first { $0.id == id }?.severity ?? .ok
    }

    private var topConsumers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top memory").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $showProcesses) {
                    Text("Apps").tag(false)
                    Text("Processes").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            if showProcesses {
                ForEach(monitor.processes.prefix(10)) { process in
                    ConsumerRow(name: process.name,
                                detail: process.startTime.map { "pid \(process.pid) · \(Format.age(since: $0))" } ?? "pid \(process.pid)",
                                bytes: process.footprint)
                }
            } else {
                ForEach(monitor.apps.prefix(10)) { app in
                    ConsumerRow(name: app.name,
                                detail: app.processCount == 1 ? "1 process" : "\(app.processCount) processes",
                                bytes: app.footprint)
                }
            }

            Text("Your processes only. System daemons and WindowServer need admin rights to read.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Refresh") { Task { await monitor.refresh() } }
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Needs the bundled app (scripts/bundle.sh): \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct MetricGauge: View {
    let title: String
    let value: String
    let fraction: Double
    let detail: String
    let severity: Severity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(value).font(.subheadline.monospacedDigit())
            }
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(severity == .ok ? .accentColor : severity.color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: insight.severity.symbolName)
                .foregroundStyle(insight.severity.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.callout.weight(.medium))
                Text(insight.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConsumerRow: View {
    let name: String
    let detail: String
    let bytes: UInt64

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.memory(bytes)).monospacedDigit()
        }
        .font(.callout)
    }
}

private extension MemoryPressure {
    var label: String {
        switch self {
        case .normal: "normal"
        case .warning: "elevated"
        case .critical: "critical"
        }
    }

    var severity: Severity {
        switch self {
        case .normal: .ok
        case .warning: .warning
        case .critical: .critical
        }
    }
}
