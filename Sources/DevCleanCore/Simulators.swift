import Foundation

public struct SimulatorDevice: Sendable, Equatable {
    public var udid: String
    public var name: String
    public var runtime: String
    public var isAvailable: Bool
}

public enum Simulators {
    static let xcrun = "/usr/bin/xcrun"

    /// All simulator devices, via `xcrun simctl list devices -j`. Empty if Xcode isn't installed.
    public static func devices() -> [SimulatorDevice] {
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrun)
        process.arguments = ["simctl", "list", "devices", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        // Read before waiting: the JSON can exceed the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? parse(data) : []
    }

    public static func parse(_ data: Data) -> [SimulatorDevice] {
        struct Listing: Decodable {
            struct Device: Decodable {
                var udid: String
                var name: String
                var isAvailable: Bool?
            }
            var devices: [String: [Device]]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        return listing.devices.flatMap { runtime, devices in
            devices.map {
                SimulatorDevice(udid: $0.udid, name: $0.name,
                                runtime: runtime.split(separator: ".").last.map(String.init) ?? runtime,
                                isAvailable: $0.isAvailable ?? true)
            }
        }
        .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
    }

    public static func deviceFolder(_ device: SimulatorDevice, home: String) -> String {
        home + "/Library/Developer/CoreSimulator/Devices/" + device.udid
    }
}
