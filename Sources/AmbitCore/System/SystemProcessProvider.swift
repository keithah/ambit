import Foundation

public struct SystemProcessProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemProcesses
    public let displayName = "System Processes"
    public let typeID: ProviderTypeID = "processes"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemProcesses
    public let pollInterval: TimeInterval

    private let processRunner: any ProcessRunner
    private let executable: String
    private let limit: Int

    public init(
        processRunner: any ProcessRunner = SystemProcessRunner(),
        executable: String = "/bin/ps",
        limit: Int = 8,
        pollInterval: TimeInterval = 5
    ) {
        self.processRunner = processRunner
        self.executable = executable
        self.limit = limit
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        [
            descriptor("top_cpu", "Top CPU", capability: "system.cpu"),
            descriptor("top_memory", "Top Memory", capability: "system.memory")
        ]
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        do {
            let result = try await processRunner.run(
                executable: executable,
                arguments: ["axo", "pid,pcpu,rss,comm"],
                timeout: 5
            )
            guard result.exitCode == 0 else {
                return ProviderSnapshot(health: .unknown, error: result.stderr)
            }
            let rows = PSProcessParser.parse(result.stdout)
            return ProviderSnapshot(health: .ok, metrics: [
                Metric(id: "top_cpu", label: "Top CPU", value: .table(table(from: rows.sorted { $0.cpuPercent > $1.cpuPercent }))),
                Metric(id: "top_memory", label: "Top Memory", value: .table(table(from: rows.sorted { $0.memoryBytes > $1.memoryBytes })))
            ])
        } catch {
            return ProviderSnapshot(health: .unknown, error: error.localizedDescription)
        }
    }

    private func descriptor(_ key: String, _ name: String, capability: ProviderCapability) -> EntityDescriptor {
        EntityDescriptor(
            id: instanceID.entity(key),
            instanceID: instanceID,
            name: name,
            kind: .table,
            category: .primary,
            capability: capability,
            access: .read,
            metricID: key,
            defaultVisibility: .auto
        )
    }

    private func table(from rows: [PSProcessRow]) -> TableValue {
        TableValue(
            columns: [
                TableColumn(id: "pid", title: "PID", alignment: .trailing, valueStyle: .number),
                TableColumn(id: "name", title: "Name"),
                TableColumn(id: "cpu", title: "CPU%", alignment: .trailing, valueStyle: .number),
                TableColumn(id: "memory", title: "Memory", alignment: .trailing, valueStyle: .number)
            ],
            rows: rows.prefix(limit).map { row in
                TableRow(id: row.rowID, cells: [
                    "pid": .number(Double(row.pid), unit: nil),
                    "name": .text(row.name),
                    "cpu": .number(row.cpuPercent, unit: "%"),
                    "memory": .number(row.memoryBytes, unit: "B")
                ])
            }
        )
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
