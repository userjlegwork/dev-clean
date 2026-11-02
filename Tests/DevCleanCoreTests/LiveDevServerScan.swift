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
            for server in project.servers {
                print("    \(server.process.pid) \(server.label)")
            }
        }
    }
}
