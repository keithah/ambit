import Foundation

public struct SystemOverviewProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemOverview
    public let displayName = "System"
    public let typeID: ProviderTypeID = "overview"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemOverview
    public let pollInterval: TimeInterval

    private let reader: any SystemMetricsReading
    private let coreCountHint: Int

    public init(
        reader: any SystemMetricsReading = DarwinSystemMetricsReader(),
        pollInterval: TimeInterval = 2,
        coreCountHint: Int = max(ProcessInfo.processInfo.processorCount, 1)
    ) {
        self.reader = reader
        self.pollInterval = pollInterval
        self.coreCountHint = max(coreCountHint, 0)
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        var descriptors = [
            EntityProjection.healthDescriptor(instanceID: instance),
            descriptor("cpu_usage_percent", "CPU", .percent, capability: "system.cpu",
                       graphStyle: .gauge, isPrimary: true,
                       priority: 100,
                       displayThreshold: DisplayThreshold(comparison: .greaterThan, value: 85, consecutive: 3)),
            descriptor("cpu_user_percent", "User", .percent, capability: "system.cpu"),
            descriptor("cpu_system_percent", "System", .percent, capability: "system.cpu"),
            descriptor("memory_used_percent", "Memory", .percent, capability: "system.memory", graphStyle: .progress, isPrimary: true),
            descriptor("memory_pressure_percent", "Memory Pressure", .percent, capability: "system.memory", graphStyle: .gauge),
            descriptor("memory_app_active_bytes", "App/Active", .dataSize, capability: "system.memory", unit: "B", graphStyle: .progress, priority: 30, compositionRole: .segment),
            descriptor("memory_wired_bytes", "Wired", .dataSize, capability: "system.memory", unit: "B", graphStyle: .progress, priority: 20, compositionRole: .segment),
            descriptor("memory_compressed_bytes", "Compressed", .dataSize, capability: "system.memory", unit: "B", graphStyle: .progress, priority: 10, compositionRole: .segment),
            descriptor("memory_cached_inactive_bytes", "Cached/Inactive", .dataSize, capability: "system.memory", unit: "B", graphStyle: .progress, priority: 5, compositionRole: .segment),
            descriptor("memory_free_bytes", "Free", .dataSize, capability: "system.memory", unit: "B", graphStyle: .progress, priority: 0, compositionRole: .remainder),
            descriptor("memory_used_bytes", "Memory Used", .dataSize, capability: "system.memory", unit: "B"),
            descriptor("battery_percent", "Battery", .battery, capability: "power.battery", graphStyle: .progress),
            descriptor("battery_charging", "Charging", .battery, kind: .binarySensor, capability: "power.battery"),
            descriptor("load_1m", "Load 1m", .count, capability: "system.cpu"),
            descriptor("uptime_seconds", "Uptime", .duration, capability: "system.cpu", unit: "s")
        ]
        descriptors.append(contentsOf: (0..<coreCountHint).map { index in
            descriptor("cpu_core_\(index)_percent", "Core \(index + 1)", .percent, capability: "system.cpu",
                       unit: "%", graphStyle: .gauge, priority: 50 - index, compositionRole: .channel)
        })
        return descriptors
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        do {
            let snapshot = try await reader.snapshot()
            return ProviderSnapshot(health: .ok, metrics: Self.metrics(from: snapshot))
        } catch {
            return ProviderSnapshot(health: .unknown, error: error.localizedDescription)
        }
    }

    private func descriptor(
        _ key: String,
        _ name: String,
        _ deviceClass: DeviceClass?,
        kind: EntityKind = .sensor,
        capability: ProviderCapability,
        unit: String? = nil,
        graphStyle: GraphStyle? = nil,
        isPrimary: Bool = false,
        priority: Int? = nil,
        compositionRole: EntityCompositionRole? = nil,
        displayThreshold: DisplayThreshold? = nil
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: instanceID.entity(key),
            instanceID: instanceID,
            name: name,
            kind: kind,
            deviceClass: deviceClass,
            category: .primary,
            capability: capability,
            access: .read,
            unit: unit,
            stateClass: .measurement,
            metricID: key,
            defaultVisibility: .auto,
            displayThreshold: displayThreshold,
            graphStyle: graphStyle,
            isPrimary: isPrimary,
            priority: priority,
            compositionRole: compositionRole
        )
    }

    private static func metrics(from snapshot: SystemMetricsSnapshot) -> [Metric] {
        let memoryPercent: Double
        if snapshot.memory.totalBytes > 0 {
            memoryPercent = (Double(snapshot.memory.usedBytes) / Double(snapshot.memory.totalBytes)) * 100
        } else {
            memoryPercent = 0
        }

        var metrics = [
            Metric(id: "cpu_usage_percent", label: "CPU", value: .percent(snapshot.cpu.userPercent + snapshot.cpu.systemPercent)),
            Metric(id: "cpu_user_percent", label: "User", value: .percent(snapshot.cpu.userPercent)),
            Metric(id: "cpu_system_percent", label: "System", value: .percent(snapshot.cpu.systemPercent)),
            Metric(id: "memory_used_percent", label: "Memory", value: .percent(memoryPercent)),
            Metric(id: "memory_used_bytes", label: "Memory Used", value: .level(Double(snapshot.memory.usedBytes)))
        ]
        if let pressurePercent = snapshot.memory.pressurePercent {
            metrics.append(Metric(id: "memory_pressure_percent", label: "Memory Pressure", value: .percent(pressurePercent)))
        }
        if let appActiveBytes = snapshot.memory.appActiveBytes {
            metrics.append(Metric(id: "memory_app_active_bytes", label: "App/Active", value: .level(Double(appActiveBytes))))
        }
        metrics.append(Metric(id: "memory_wired_bytes", label: "Wired", value: .level(Double(snapshot.memory.wiredBytes))))
        metrics.append(Metric(id: "memory_compressed_bytes", label: "Compressed", value: .level(Double(snapshot.memory.compressedBytes))))
        if let cachedInactiveBytes = snapshot.memory.cachedInactiveBytes {
            metrics.append(Metric(id: "memory_cached_inactive_bytes", label: "Cached/Inactive", value: .level(Double(cachedInactiveBytes))))
        }
        if let freeBytes = snapshot.memory.freeBytes {
            metrics.append(Metric(id: "memory_free_bytes", label: "Free", value: .level(Double(freeBytes))))
        }
        if snapshot.battery.isPresent {
            metrics.append(Metric(id: "battery_percent", label: "Battery", value: .level(snapshot.battery.percent)))
            metrics.append(Metric(id: "battery_charging", label: "Charging", value: .bool(snapshot.battery.isCharging)))
        }
        if let load = snapshot.cpu.loadAverages.first {
            metrics.append(Metric(id: "load_1m", label: "Load 1m", value: .level(load)))
        }
        if let uptimeSeconds = snapshot.uptimeSeconds {
            metrics.append(Metric(id: "uptime_seconds", label: "Uptime", value: .level(uptimeSeconds)))
        }
        for (index, coreUsage) in snapshot.cpu.coreUsagePercents.enumerated() {
            metrics.append(Metric(id: "cpu_core_\(index)_percent", label: "Core \(index + 1)", value: .percent(coreUsage)))
        }
        return metrics
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
