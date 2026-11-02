import Foundation

public struct CommandOutput: Sendable {
    public var status: Int32
    public var output: String
    public var timedOut: Bool

    /// Last line of output, for one-line error messages.
    public var tail: String {
        output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

public enum CommandRunner {
    /// Runs a tool with a PATH that includes Homebrew and the newest nvm Node (GUI apps get a bare PATH,
    /// and tools like pnpm are Node scripts). Output goes to a temp file so a chatty tool can't fill a pipe and hang.
    public static func run(_ executable: String, _ arguments: [String],
                           timeout: Duration = .seconds(600)) async -> CommandOutput {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("devclean-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            return CommandOutput(status: -1, output: "Couldn't create output file", timedOut: false)
        }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = toolPath()
        process.environment = environment

        let box = ProcessBox(process)
        let timer = Task {
            try await Task.sleep(for: timeout)
            // Flag first: once terminated, the continuation can resume and read it.
            box.timedOut = true
            box.process.terminate()
        }

        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        timer.cancel()

        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return CommandOutput(status: status, output: output, timedOut: box.timedOut)
    }

    static func toolPath(home: String = NSHomeDirectory()) -> String {
        var path = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm),
           let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            path.append("\(nvm)/\(newest)/bin")
        }
        path += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return path.joined(separator: ":")
    }
}

/// Lets the timeout task reach the Process. Access is ordered by the continuation, not concurrent.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    var timedOut = false
    init(_ process: Process) { self.process = process }
}
