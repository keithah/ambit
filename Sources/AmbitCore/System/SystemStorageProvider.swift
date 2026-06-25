import Foundation

public struct SystemStorageProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemStorage
    public let displayName = "System Storage"
    public let typeID: ProviderTypeID = "storage"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemStorage
    public let pollInterval: TimeInterval

    private let reader: any SystemMetricsReading

    public init(reader: any SystemMetricsReading = DarwinSystemMetricsReader(), pollInterval: TimeInterval = 5) {
        self.reader = reader
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        [
            EntityDescriptor(
                id: instanceID.entity("volumes"),
                instanceID: instanceID,
                name: "Volumes",
                kind: .table,
                category: .primary,
                capability: "system.disk",
                access: .read,
                metricID: "volumes",
                defaultVisibility: .auto
            )
        ]
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        do {
            let snapshot = try await reader.snapshot()
            return ProviderSnapshot(health: .ok, metrics: [
                Metric(id: "volumes", label: "Volumes", value: .table(Self.table(from: snapshot.diskVolumes)))
            ])
        } catch {
            return ProviderSnapshot(health: .unknown, error: error.localizedDescription)
        }
    }

    private static func table(from volumes: [DiskVolumeMetrics]) -> TableValue {
        TableValue(
            columns: [
                TableColumn(id: "volume", title: "Volume"),
                TableColumn(id: "mount", title: "Mount"),
                TableColumn(id: "used", title: "Used", alignment: .trailing, valueStyle: .number),
                TableColumn(id: "available", title: "Available", alignment: .trailing, valueStyle: .number),
                TableColumn(id: "total", title: "Total", alignment: .trailing, valueStyle: .number)
            ],
            rows: volumes.map { volume in
                let used = volume.totalBytes > volume.availableBytes ? volume.totalBytes - volume.availableBytes : 0
                return TableRow(id: volume.mountPath, cells: [
                    "volume": .text(volume.volumeName),
                    "mount": .text(volume.mountPath),
                    "used": .number(Double(used), unit: "B"),
                    "available": .number(Double(volume.availableBytes), unit: "B"),
                    "total": .number(Double(volume.totalBytes), unit: "B")
                ])
            }
        )
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
