import Foundation

public struct SystemIntegration: Integration {
    public let id = IntegrationIDs.system
    public let displayName = "System"

    private let reader: any SystemMetricsReading
    private let processRunner: any ProcessRunner
    private let sensorReader: any SystemSensorReading

    public init(
        reader: any SystemMetricsReading = DarwinSystemMetricsReader(),
        processRunner: any ProcessRunner = SystemProcessRunner(),
        sensorReader: any SystemSensorReading = NoOpSystemSensorReader()
    ) {
        self.reader = reader
        self.processRunner = processRunner
        self.sensorReader = sensorReader
    }

    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [
            SystemOverviewProvider(reader: reader),
            SystemStorageProvider(reader: reader),
            SystemProcessProvider(processRunner: processRunner),
            SystemNetworkProvider(reader: reader),
            SystemSensorProvider(reader: sensorReader),
            SystemFanProvider(reader: sensorReader)
        ]
    }
}
