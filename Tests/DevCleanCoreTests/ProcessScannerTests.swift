import Foundation
import Testing
@testable import DevCleanCore

@Suite struct AppNameTests {
    @Test func helperGroupsUnderOutermostApp() {
        let path = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        #expect(ProcessScanner.appName(forExecutablePath: path, fallback: "x") == "Visual Studio Code")
    }

    @Test func plainBinaryKeepsItsName() {
        #expect(ProcessScanner.appName(forExecutablePath: "/Users/me/.nvm/versions/node/v24/bin/node", fallback: "x") == "node")
    }

    @Test func missingPathUsesFallback() {
        #expect(ProcessScanner.appName(forExecutablePath: nil, fallback: "loginwindow") == "loginwindow")
    }
}

@Suite struct GroupingTests {
    @Test func sumsFootprintsAndSortsLargestFirst() {
        let samples = [
            ProcessSample(pid: 1, name: "Slack Helper", executablePath: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", footprint: 300, startTime: nil),
            ProcessSample(pid: 2, name: "Slack", executablePath: "/Applications/Slack.app/Contents/MacOS/Slack", footprint: 200, startTime: nil),
            ProcessSample(pid: 3, name: "node", executablePath: "/usr/local/bin/node", footprint: 400, startTime: nil),
        ]
        let groups = ProcessScanner.group(samples)
        #expect(groups.map(\.name) == ["Slack", "node"])
        #expect(groups[0].footprint == 500)
        #expect(groups[0].processCount == 2)
    }
}

@Suite struct LiveSystemTests {
    @Test func scanFindsThisProcess() {
        let me = ProcessScanner.scan().first { $0.pid == getpid() }
        #expect(me != nil)
        #expect((me?.footprint ?? 0) > 0)
    }

    @Test func snapshotReadsPlausibleValues() throws {
        let snapshot = try SystemMetrics.snapshot()
        #expect(snapshot.memory.total > 1 << 30)
        #expect(snapshot.memory.used <= snapshot.memory.total)
        #expect(snapshot.disk.total > snapshot.disk.free)
        #expect(snapshot.uptime > 0)
    }
}
