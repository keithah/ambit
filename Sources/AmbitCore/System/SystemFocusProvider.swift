import Foundation

public enum SystemFocusAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public struct SystemFocusSnapshot: Equatable, Sendable {
    public var availability: SystemFocusAvailability
    public var isActive: Bool?
    public var mode: String?

    public init(availability: SystemFocusAvailability, isActive: Bool? = nil, mode: String? = nil) {
        self.availability = availability
        self.isActive = isActive
        self.mode = mode
    }
}

public protocol SystemFocusReading: Sendable {
    func snapshot() async -> SystemFocusSnapshot
}

public struct NoOpSystemFocusReader: SystemFocusReading {
    public init() {}
    public func snapshot() async -> SystemFocusSnapshot {
        // macOS does not expose a reliable public Focus-mode read API suitable for
        // this provider. Keep the entity shape present and unavailable.
        SystemFocusSnapshot(availability: .unavailable)
    }
}

public struct SystemFocusProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemFocus
    public let displayName = "Focus"
    public let typeID: ProviderTypeID = "focus"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemFocus
    public let pollInterval: TimeInterval

    private let reader: any SystemFocusReading

    public init(reader: any SystemFocusReading = NoOpSystemFocusReader(), pollInterval: TimeInterval = 30) {
        self.reader = reader
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        [
            EntityDescriptor(
                id: instanceID.entity("active"),
                instanceID: instanceID,
                name: "Focus Active",
                kind: .binarySensor,
                category: .primary,
                capability: "system.focus",
                access: .read,
                metricID: "active",
                defaultVisibility: .auto
            ),
            EntityDescriptor(
                id: instanceID.entity("mode"),
                instanceID: instanceID,
                name: "Focus Mode",
                kind: .text,
                category: .primary,
                capability: "system.focus",
                access: .read,
                metricID: "mode",
                defaultVisibility: .auto
            )
        ]
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        let snapshot = await reader.snapshot()
        guard snapshot.availability == .available else {
            return ProviderSnapshot(health: .ok)
        }
        var metrics: [Metric] = []
        if let isActive = snapshot.isActive {
            metrics.append(Metric(id: "active", label: "Focus Active", value: .bool(isActive), capability: "system.focus"))
        }
        if let mode = snapshot.mode, !mode.isEmpty {
            metrics.append(Metric(id: "mode", label: "Focus Mode", value: .text(mode), capability: "system.focus"))
        }
        return ProviderSnapshot(health: .ok, metrics: metrics)
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
