import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(IOKit.ps)
import IOKit.ps
#endif

public struct DarwinSystemMetricsReader: SystemMetricsReading {
    public init() {}

    public func snapshot() async throws -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: try Self.cpuMetrics(),
            memory: try Self.memoryMetrics(),
            diskVolumes: Self.diskVolumes(),
            networkCounters: Self.networkCounters(),
            battery: Self.batteryMetrics(),
            processes: [],
            uptimeSeconds: Self.uptimeSeconds()
        )
    }
}

#if canImport(Darwin)
private extension DarwinSystemMetricsReader {
    static func cpuMetrics() throws -> CPUMetrics {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SystemMetricsReaderError.probeFailed("host_statistics(HOST_CPU_LOAD_INFO) failed: \(result)")
        }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let total = max(user + system + idle + nice, 1)
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, Int32(loads.count))
        if loadCount < loads.count {
            loads = Array(loads.prefix(max(Int(loadCount), 0)))
        }

        let coreUsagePercents = Self.coreUsagePercents()

        return CPUMetrics(
            userPercent: ((user + nice) / total) * 100,
            systemPercent: (system / total) * 100,
            idlePercent: (idle / total) * 100,
            coreCount: max(coreUsagePercents.count, ProcessInfo.processInfo.processorCount, 1),
            loadAverages: loads,
            coreUsagePercents: coreUsagePercents
        )
    }

    static func coreUsagePercents() -> [Double] {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else { return [] }
        defer {
            let byteCount = vm_size_t(Int(processorInfoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: processorInfo)), byteCount)
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(processorCount)).compactMap { index in
            let base = index * stride
            guard base + Int(CPU_STATE_MAX) <= Int(processorInfoCount) else { return nil }
            let user = Double(processorInfo[base + Int(CPU_STATE_USER)])
            let system = Double(processorInfo[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(processorInfo[base + Int(CPU_STATE_IDLE)])
            let nice = Double(processorInfo[base + Int(CPU_STATE_NICE)])
            let total = user + system + idle + nice
            guard total > 0 else { return 0 }
            return min(max(((user + system + nice) / total) * 100, 0), 100)
        }
    }

    static func memoryMetrics() throws -> MemoryMetrics {
        var totalBytes: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &totalBytes, &totalSize, nil, 0) == 0 else {
            throw SystemMetricsReaderError.probeFailed("sysctl(hw.memsize) failed.")
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SystemMetricsReaderError.probeFailed("host_statistics64(HOST_VM_INFO64) failed: \(result)")
        }

        var pageSizeValue = vm_size_t()
        let pageResult = host_page_size(mach_host_self(), &pageSizeValue)
        guard pageResult == KERN_SUCCESS else {
            throw SystemMetricsReaderError.probeFailed("host_page_size failed: \(pageResult)")
        }
        let pageSize = UInt64(pageSizeValue)
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let used = min(active + inactive + wired + compressed, totalBytes)
        let pressurePercent: Double? = totalBytes > 0
            ? min(max((Double(active + wired + compressed) / Double(totalBytes)) * 100, 0), 100)
            : nil

        return MemoryMetrics(
            usedBytes: used,
            wiredBytes: wired,
            compressedBytes: compressed,
            totalBytes: totalBytes,
            pressurePercent: pressurePercent,
            appActiveBytes: active,
            freeBytes: min(free, totalBytes)
        )
    }

    static func diskVolumes() -> [DiskVolumeMetrics] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  total > 0
            else { return nil }
            let available = values.volumeAvailableCapacity ?? 0
            return DiskVolumeMetrics(
                mountPath: url.path,
                totalBytes: UInt64(total),
                availableBytes: UInt64(max(available, 0)),
                volumeName: values.volumeName ?? url.lastPathComponent
            )
        }
    }

    static func networkCounters() -> [NetworkCounterMetrics] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }

        var byName: [String: NetworkCounterMetrics] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            let flags = UInt32(interface.ifa_flags)
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                byName[name] = NetworkCounterMetrics(
                    interfaceName: name,
                    bytesIn: UInt64(data.ifi_ibytes),
                    bytesOut: UInt64(data.ifi_obytes),
                    isLoopback: isLoopback
                )
            }
            cursor = interface.ifa_next
        }
        return byName.values.sorted { $0.interfaceName < $1.interfaceName }
    }

    static func uptimeSeconds() -> TimeInterval? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0) == 0 else {
            return nil
        }
        let bootTimestamp = TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
        return max(0, Date().timeIntervalSince1970 - bootTimestamp)
    }
}
#else
private extension DarwinSystemMetricsReader {
    static func cpuMetrics() throws -> CPUMetrics {
        throw SystemMetricsReaderError.unsupportedPlatform
    }

    static func memoryMetrics() throws -> MemoryMetrics {
        throw SystemMetricsReaderError.unsupportedPlatform
    }

    static func diskVolumes() -> [DiskVolumeMetrics] { [] }
    static func networkCounters() -> [NetworkCounterMetrics] { [] }
    static func uptimeSeconds() -> TimeInterval? { nil }
}
#endif

private extension DarwinSystemMetricsReader {
    static func batteryMetrics() -> BatteryMetrics {
        #if canImport(IOKit.ps)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else {
            return BatteryMetrics(percent: 0, isCharging: false, isPresent: false)
        }

        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any]
            else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maxCapacity = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent: Double
            if let current, let maxCapacity, maxCapacity > 0 {
                percent = min(Swift.max((current / maxCapacity) * 100, 0), 100)
            } else {
                percent = 0
            }
            let isCharging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
            return BatteryMetrics(percent: percent, isCharging: isCharging, isPresent: true)
        }
        return BatteryMetrics(percent: 0, isCharging: false, isPresent: false)
        #else
        return BatteryMetrics(percent: 0, isCharging: false, isPresent: false)
        #endif
    }
}

public enum SystemMetricsReaderError: Error, Equatable, Sendable {
    case unsupportedPlatform
    case probeFailed(String)
}
