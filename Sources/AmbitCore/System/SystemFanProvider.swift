import Foundation

public struct SystemFanProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemFans
    public let displayName = "System Fans"
    public let typeID: ProviderTypeID = "fans"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemFans
    public let pollInterval: TimeInterval

    private let reader: any SystemSensorReading

    public init(reader: any SystemSensorReading = NoOpSystemSensorReader(), pollInterval: TimeInterval = 5) {
        self.reader = reader
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        [
            EntityDescriptor(
                id: instanceID.entity("fans"),
                instanceID: instanceID,
                name: "Fans",
                kind: .table,
                deviceClass: .fan,
                category: .primary,
                capability: "system.fans",
                access: .read,
                metricID: "fans",
                defaultVisibility: reader.isAvailable ? .auto : .never
            )
        ]
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        guard reader.isAvailable else {
            return ProviderSnapshot(health: .ok)
        }
        do {
            let snapshot = try await reader.snapshot()
            return ProviderSnapshot(health: .ok, metrics: [
                Metric(id: "fans", label: "Fans", value: .table(Self.table(from: snapshot.fans)))
            ])
        } catch {
            return ProviderSnapshot(health: .ok)
        }
    }

    private static func table(from fans: [FanSpeedMetrics]) -> TableValue {
        TableValue(
            columns: [
                TableColumn(id: "fan", title: "Fan"),
                TableColumn(id: "rpm", title: "RPM", alignment: .trailing, valueStyle: .number)
            ],
            rows: fans.map { fan in
                TableRow(id: fan.name, cells: [
                    "fan": .text(fan.name),
                    "rpm": .number(fan.rpm, unit: "rpm")
                ])
            }
        )
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
