import Darwin
import Foundation

public struct ProcessSample: Sendable, Identifiable, Equatable {
    public var pid: Int32
    public var name: String
    public var executablePath: String?
    /// `ri_phys_footprint`: the "Memory" column in Activity Monitor, including compressed and swapped pages.
    public var footprint: UInt64
    public var startTime: Date?
    /// 1 (launchd) once the process that started it has exited.
    public var parentPID: Int32?

    public var id: Int32 { pid }
    public var appName: String { ProcessScanner.appName(forExecutablePath: executablePath, fallback: name) }

    public init(pid: Int32, name: String, executablePath: String?, footprint: UInt64, startTime: Date?, parentPID: Int32? = nil) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.footprint = footprint
        self.startTime = startTime
        self.parentPID = parentPID
    }
}

public struct AppGroup: Sendable, Identifiable, Equatable {
    public var name: String
    public var footprint: UInt64
    public var pids: [Int32]

    public var id: String { name }
    public var processCount: Int { pids.count }
}

public enum ProcessScanner {
    /// Samples every process this user can inspect. Other users' processes (WindowServer, root daemons)
    /// are skipped because reading their memory needs root.
    public static func scan() -> [ProcessSample] {
        allPIDs().compactMap(sample(pid:))
    }

    public static func sample(pid: Int32) -> ProcessSample? {
        guard pid > 0, let footprint = footprint(pid: pid) else { return nil }
        let path = executablePath(pid: pid)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? shortName(pid: pid) ?? "pid \(pid)"
        let info = bsdInfo(pid: pid)
        return ProcessSample(pid: pid, name: name, executablePath: path, footprint: footprint,
                             startTime: info.map(startTime(of:)) ?? startTime(pid: pid), parentPID: info.map { Int32($0.pbi_ppid) })
    }

    /// Groups helpers under their outermost app bundle, largest first.
    public static func group(_ samples: [ProcessSample]) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        for sample in samples {
            let name = sample.appName
            groups[name, default: AppGroup(name: name, footprint: 0, pids: [])].footprint += sample.footprint
            groups[name]!.pids.append(sample.pid)
        }
        return groups.values.sorted { $0.footprint > $1.footprint }
    }

    /// "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/…" → "Visual Studio Code".
    /// Anything outside an app bundle keeps its executable name.
    public static func appName(forExecutablePath path: String?, fallback: String) -> String {
        guard let path else { return fallback }
        if let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        return (path as NSString).lastPathComponent
    }

    // MARK: - libproc

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    static func footprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func shortName(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func startTime(pid: Int32) -> Date? {
        bsdInfo(pid: pid).map(startTime(of:))
    }

    /// True while `pid` is running and is still the process that started at `startedAt`
    /// (guards against PID reuse). Zombies count as exited.
    public static func isRunning(pid: Int32, startedAt: Date?) -> Bool {
        guard let info = bsdInfo(pid: pid) else { return false }
        if info.pbi_status == 5 { return false } // SZOMB
        if let startedAt, abs(startTime(of: info).timeIntervalSince(startedAt)) > 1 { return false }
        return true
    }

    /// Full argv, read via KERN_PROCARGS2. Only works for this user's processes.
    public static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        // Layout: argc, exec path, NUL padding, then argc NUL-terminated strings.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    static func bsdInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func startTime(of info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
