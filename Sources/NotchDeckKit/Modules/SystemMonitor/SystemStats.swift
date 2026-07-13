import Foundation
import Darwin

/// One host_processor_info sample: per-core [user, system, idle, nice] ticks.
public struct CPUSample: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum SystemStatsMath {
    /// Busy fraction (0...1) between two cumulative tick samples. Tested.
    public static func cpuUsage(previous: CPUSample, current: CPUSample) -> Double {
        let busy = (current.user &- previous.user)
            &+ (current.system &- previous.system)
            &+ (current.nice &- previous.nice)
        let idle = current.idle &- previous.idle
        let total = busy &+ idle
        guard total > 0 else { return 0 }
        return Double(busy) / Double(total)
    }
}

struct MemorySnapshot {
    var usedBytes: UInt64
    var totalBytes: UInt64
}

struct StorageSnapshot {
    var freeBytes: Int64
    var totalBytes: Int64
}

enum SystemStatsSampler {
    static func cpuSample() -> CPUSample? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUSample(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    static func memory() -> MemorySnapshot? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSizeValue: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeValue)
        let pageSize = UInt64(pageSizeValue)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * pageSize
        return MemorySnapshot(
            usedBytes: used,
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    static func storage() -> StorageSnapshot? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]), let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity else { return nil }
        return StorageSnapshot(freeBytes: free, totalBytes: Int64(total))
    }
}
