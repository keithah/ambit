import Foundation

public struct SystemMetricsSnapshot: Equatable, Sendable, Codable {
    public var cpu: CPUMetrics
    public var memory: MemoryMetrics
    public var diskVolumes: [DiskVolumeMetrics]
    public var networkCounters: [NetworkCounterMetrics]
    public var battery: BatteryMetrics
    public var processes: [ProcessMetrics]

    public init(
        cpu: CPUMetrics,
        memory: MemoryMetrics,
        diskVolumes: [DiskVolumeMetrics] = [],
        networkCounters: [NetworkCounterMetrics] = [],
        battery: BatteryMetrics = BatteryMetrics(percent: 0, isCharging: false, isPresent: false),
        processes: [ProcessMetrics] = []
    ) {
        self.cpu = cpu
        self.memory = memory
        self.diskVolumes = diskVolumes
        self.networkCounters = networkCounters
        self.battery = battery
        self.processes = processes
    }
}

public struct CPUMetrics: Equatable, Sendable, Codable {
    public var userPercent: Double
    public var systemPercent: Double
    public var idlePercent: Double
    public var coreCount: Int
    public var loadAverages: [Double]

    public init(
        userPercent: Double,
        systemPercent: Double,
        idlePercent: Double,
        coreCount: Int,
        loadAverages: [Double] = []
    ) {
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
        self.coreCount = coreCount
        self.loadAverages = loadAverages
    }
}

public struct MemoryMetrics: Equatable, Sendable, Codable {
    public var usedBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var totalBytes: UInt64

    public init(usedBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.totalBytes = totalBytes
    }
}

public struct DiskVolumeMetrics: Equatable, Sendable, Codable {
    public var mountPath: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var volumeName: String

    public init(mountPath: String, totalBytes: UInt64, availableBytes: UInt64, volumeName: String) {
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.volumeName = volumeName
    }
}

public struct NetworkCounterMetrics: Equatable, Sendable, Codable {
    public var interfaceName: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var isLoopback: Bool

    public init(interfaceName: String, bytesIn: UInt64, bytesOut: UInt64, isLoopback: Bool) {
        self.interfaceName = interfaceName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.isLoopback = isLoopback
    }
}

public struct BatteryMetrics: Equatable, Sendable, Codable {
    public var percent: Double
    public var isCharging: Bool
    public var isPresent: Bool

    public init(percent: Double, isCharging: Bool, isPresent: Bool) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPresent = isPresent
    }
}

public struct ProcessMetrics: Equatable, Sendable, Codable {
    public init() {}
}
