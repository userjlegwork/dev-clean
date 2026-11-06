import Foundation
import Testing
@testable import DevCleanCore

/// Read-only dump of what the scanner sees on this machine. Run with:
/// DEVCLEAN_LIVE=1 swift test --filter LiveDevServerScan
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVCLEAN_LIVE"] != nil))
struct LiveDevServerScan {
    @Test func printProjects() {
        let rules = DevServerRules()
        for project in DevServerScanner.scan(ProcessScanner.scan(), rules: rules) {
            let flag = project.isProtected ? "PROTECTED" : project.isStale(after: rules.staleAfter) ? "STALE" : "recent"
            let age = project.newestStart.map { Format.age(since: $0) } ?? "?"
            print("[\(flag)] \(project.displayName()) · newest \(age) · \(Format.memory(project.footprint))")
            let duplicates = project.duplicateInstanceIDs
            for instance in project.instances {
                let tags = [duplicates.contains(instance.id) ? "duplicate" : nil, instance.isDetached ? "detached" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                print("  \(instance.label) [\(tags)] started \(instance.startTime.map { Format.age(since: $0) } ?? "?") ago")
                for process in instance.launchers { print("    \(process.pid) \(process.name) (launcher)") }
                for server in instance.servers { print("    \(server.process.pid) \(server.label)") }
            }
        }
    }
}
