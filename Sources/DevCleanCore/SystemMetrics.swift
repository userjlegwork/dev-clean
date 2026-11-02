import Darwin
import Foundation

public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

public struct MemorySnapshot: Sendable, Equatable {
    public var total: UInt64
    /// Anonymous memory owned by apps, minus purgeable (Activity Monitor's "App Memory").
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File-backed and purgeable pages the kernel can drop at any time.
    public var cached: UInt64
    /// `kern.memorystatus_level`, the same number `memory_pressure` prints as "free percentage".
    public var freePercent: Int
    public var pressure: MemoryPressure

    /// Matches Activity Monitor's "Memory Used".
    public var used: UInt64 { appMemory + wired + compressed }

    public init(total: UInt64, appMemory: UInt64, wired: UInt64, compressed: UInt64,
                cached: UInt64, freePercent: Int, pressure: MemoryPressure) {
        self.total = total
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.freePercent = freePercent
        self.pressure = pressure
    }
}

public struct SwapSnapshot: Sendable, Equatable {
    public var total: UInt64
    public var used: UInt64

    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public init(total: UInt64, used: UInt64) {
        self.total = total
        self.used = used
    }
}

public struct DiskSnapshot: Sendable, Equatable {
    public var total: UInt64
    /// Free space right now (what `df` reports).
    public var free: UInt64
    /// Free space plus purgeable space macOS would reclaim for the user (what Finder reports).
    public var availableForImportantUsage: UInt64

    public var used: UInt64 { total > free ? total - free : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public init(total: UInt64, free: UInt64, availableForImportantUsage: UInt64) {
        self.total = total
        self.free = free
        self.availableForImportantUsage = availableForImportantUsage
    }
}

public struct SystemSnapshot: Sendable, Equatable {
    public var memory: MemorySnapshot
    public var swap: SwapSnapshot
    public var disk: DiskSnapshot
    public var bootTime: Date
    public var takenAt: Date

    public var uptime: TimeInterval { takenAt.timeIntervalSince(bootTime) }
    public var uptimeDays: Int { Int(uptime / 86_400) }

    public init(memory: MemorySnapshot, swap: SwapSnapshot, disk: DiskSnapshot,
                bootTime: Date, takenAt: Date = Date()) {
        self.memory = memory
        self.swap = swap
        self.disk = disk
        self.bootTime = bootTime
        self.takenAt = takenAt
    }
}

public enum SystemMetricsError: Error, CustomStringConvertible {
    case sysctl(String)
    case hostStatistics(kern_return_t)
    case volume(String)

    public var description: String {
        switch self {
        case .sysctl(let name): "Could not read sysctl \(name)"
        case .hostStatistics(let code): "host_statistics64 failed (\(code))"
        case .volume(let path): "Could not read capacity of \(path)"
        }
    }
}

public enum SystemMetrics {
    public static func snapshot(volume: URL = URL(fileURLWithPath: "/")) throws -> SystemSnapshot {
        SystemSnapshot(
            memory: try memory(),
            swap: try swap(),
            disk: try disk(volume: volume),
            bootTime: try bootTime()
        )
    }

    public static func memory() throws -> MemorySnapshot {
        guard let total = sysctlInteger("hw.memsize") else { throw SystemMetricsError.sysctl("hw.memsize") }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw SystemMetricsError.hostStatistics(result) }

        let page = UInt64(getpagesize())
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let level = sysctlInteger("kern.memorystatus_level") ?? 0
        let pressureLevel = sysctlInteger("kern.memorystatus_vm_pressure_level") ?? 1

        return MemorySnapshot(
            total: UInt64(total),
            appMemory: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            freePercent: Int(level),
            pressure: MemoryPressure(rawValue: Int(pressureLevel)) ?? .normal
        )
    }

    public static func swap() throws -> SwapSnapshot {
        guard let usage: xsw_usage = sysctlStruct("vm.swapusage") else {
            throw SystemMetricsError.sysctl("vm.swapusage")
        }
        return SwapSnapshot(total: usage.xsu_total, used: usage.xsu_used)
    }

    public static func disk(volume: URL) throws -> DiskSnapshot {
        let values = try volume.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity else {
            throw SystemMetricsError.volume(volume.path)
        }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        return DiskSnapshot(total: UInt64(total), free: UInt64(free), availableForImportantUsage: UInt64(important))
    }

    public static func bootTime() throws -> Date {
        guard let boot: timeval = sysctlStruct("kern.boottime") else {
            throw SystemMetricsError.sysctl("kern.boottime")
        }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    // MARK: - sysctl helpers

    /// Reads an integer sysctl whether the kernel stores it as 32 or 64 bits.
    static func sysctlInteger(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var value: Int32 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int64(value) : nil
        case 8:
            var value: Int64 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
        default:
            return nil
        }
    }

    static func sysctlStruct<T>(_ name: String) -> T? {
        var size = MemoryLayout<T>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard sysctlbyname(name, buffer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return buffer.load(as: T.self)
    }
}
