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

    public init(reader: any SystemMetricsReading = DarwinSystemMetricsReader(), pollInterval: TimeInterval = 2) {
        self.reader = reader
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        let instance = instanceID
        return [
            EntityProjection.healthDescriptor(instanceID: instance),
            descriptor("cpu_usage_percent", "CPU", .percent, capability: "system.cpu",
                       graphStyle: .gauge, isPrimary: true,
                       displayThreshold: DisplayThreshold(comparison: .greaterThan, value: 85, consecutive: 3)),
            descriptor("cpu_user_percent", "User", .percent, capability: "system.cpu"),
            descriptor("cpu_system_percent", "System", .percent, capability: "system.cpu"),
            descriptor("memory_used_percent", "Memory", .percent, capability: "system.memory", graphStyle: .progress),
            descriptor("memory_used_bytes", "Memory Used", .dataSize, capability: "system.memory", unit: "B"),
            descriptor("battery_percent", "Battery", .battery, capability: "power.battery", graphStyle: .progress),
            descriptor("load_1m", "Load 1m", nil, capability: "system.cpu")
        ]
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
        capability: ProviderCapability,
        unit: String? = nil,
        graphStyle: GraphStyle? = nil,
        isPrimary: Bool = false,
        displayThreshold: DisplayThreshold? = nil
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: instanceID.entity(key),
            instanceID: instanceID,
            name: name,
            kind: .sensor,
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
            isPrimary: isPrimary
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
        if snapshot.battery.isPresent {
            metrics.append(Metric(id: "battery_percent", label: "Battery", value: .level(snapshot.battery.percent)))
        }
        if let load = snapshot.cpu.loadAverages.first {
            metrics.append(Metric(id: "load_1m", label: "Load 1m", value: .level(load)))
        }
        return metrics
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
