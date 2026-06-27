import Foundation

public struct SystemSensorProvider: Provider {
    public let id: ProviderID = ProviderIDs.systemSensors
    public let displayName = "System Sensors"
    public let typeID: ProviderTypeID = "sensors"
    public let integrationID = IntegrationIDs.system
    public let integrationInstanceID = IntegrationInstanceIDs.systemLocal
    public let instanceID = ProviderInstanceIDs.systemSensors
    public let pollInterval: TimeInterval

    private let reader: any SystemSensorReading
    private let temperatureNames: [String]

    public init(
        reader: any SystemSensorReading = NoOpSystemSensorReader(),
        temperatureNames: [String] = ["Temperature"],
        pollInterval: TimeInterval = 5
    ) {
        self.reader = reader
        self.temperatureNames = temperatureNames
        self.pollInterval = pollInterval
    }

    public func entityDescriptors() -> [EntityDescriptor] {
        guard reader.isAvailable else { return [] }
        return temperatureNames.map { name in
            EntityDescriptor(
                id: instanceID.entity(metricID(for: name)),
                instanceID: instanceID,
                name: name,
                kind: .sensor,
                deviceClass: .temperature,
                category: .primary,
                capability: "system.sensors",
                access: .read,
                unit: "C",
                stateClass: .measurement,
                metricID: metricID(for: name),
                defaultVisibility: .auto
            )
        }
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        guard reader.isAvailable else {
            return ProviderSnapshot(health: .ok)
        }
        do {
            let snapshot = try await reader.snapshot()
            let knownNames = Set(temperatureNames)
            let metrics = snapshot.temperatures
                .filter { knownNames.contains($0.name) }
                .map { Metric(id: metricID(for: $0.name), label: $0.name, value: .level($0.celsius)) }
            return ProviderSnapshot(health: .ok, metrics: metrics)
        } catch {
            return ProviderSnapshot(health: .ok)
        }
    }
}

private func metricID(for temperatureName: String) -> String {
    "temperature.\(temperatureName.slugForSystemSensorID)"
}

private extension String {
    var slugForSystemSensorID: String {
        lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "_"
            }
            .reduce(into: "") { result, character in
                if character == "_", result.last == "_" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

private extension ProviderInstanceID {
    func entity(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}
