import Darwin
import Foundation

public struct StopTarget: Sendable, Equatable {
    public var pid: Int32
    /// Checked before every signal so a reused PID is never hit.
    public var startTime: Date?
    public var signal: Int32

    public init(pid: Int32, startTime: Date?, signal: Int32 = SIGTERM) {
        self.pid = pid
        self.startTime = startTime
        self.signal = signal
    }
}

public struct StopReport: Sendable, Equatable {
    /// Exited after the polite signal (or were already gone).
    public var stopped: [Int32] = []
    /// Needed SIGKILL.
    public var forced: [Int32] = []
    /// Still running, or we weren't allowed to signal them.
    public var failed: [Int32] = []

    public var summary: String {
        var parts = ["Stopped \(stopped.count + forced.count)"]
        if !forced.isEmpty { parts.append("\(forced.count) forced") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.joined(separator: ", ")
    }
}

public enum ProcessStopper {
    /// Sends each target its signal, waits up to `grace` for it to exit, then SIGKILLs whatever is left.
    public static func stop(_ targets: [StopTarget], grace: Duration = .seconds(5),
                            poll: Duration = .milliseconds(250)) async -> StopReport {
        var report = StopReport()
        var signalled: [StopTarget] = []

        for target in targets {
            guard isRunning(target) else {
                report.stopped.append(target.pid)
                continue
            }
            if kill(target.pid, target.signal) == 0 {
                signalled.append(target)
            } else if errno == ESRCH {
                report.stopped.append(target.pid)
            } else {
                report.failed.append(target.pid)
            }
        }

        let survivors = await stillRunning(signalled, within: grace, poll: poll)
        report.stopped += signalled.filter { !survivors.contains($0) }.map(\.pid)

        for target in survivors where isRunning(target) {
            kill(target.pid, SIGKILL)
        }
        let stubborn = await stillRunning(survivors, within: .seconds(2), poll: poll)
        report.forced += survivors.filter { !stubborn.contains($0) }.map(\.pid)
        report.failed += stubborn.map(\.pid)
        return report
    }

    static func isRunning(_ target: StopTarget) -> Bool {
        ProcessScanner.isRunning(pid: target.pid, startedAt: target.startTime)
    }

    static func stillRunning(_ targets: [StopTarget], within timeout: Duration, poll: Duration) async -> [StopTarget] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var alive = targets.filter(isRunning)
        while !alive.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: poll)
            alive = alive.filter(isRunning)
        }
        return alive
    }
}
