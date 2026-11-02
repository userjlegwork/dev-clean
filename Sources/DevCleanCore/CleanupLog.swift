import Foundation

/// Append-only JSON-lines record of every cleanup, so it's always clear what was removed and when.
public struct CleanupLog: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var date: Date
        public var target: String
        public var action: String
        public var estimatedBytes: UInt64
        public var result: CleanupResult

        public init(date: Date, target: String, action: String, estimatedBytes: UInt64, result: CleanupResult) {
            self.date = date
            self.target = target
            self.action = action
            self.estimatedBytes = estimatedBytes
            self.result = result
        }
    }

    public var url: URL

    public static let standard = CleanupLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DevClean/cleanup.log"))

    public init(url: URL) { self.url = url }

    public func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    public func entries() -> [Entry] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
