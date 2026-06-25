import Foundation

public struct SystemIntegration: Integration {
    public let id = IntegrationIDs.system
    public let displayName = "System"

    private let reader: any SystemMetricsReading
    private let processRunner: any ProcessRunner

    public init(
        reader: any SystemMetricsReading = DarwinSystemMetricsReader(),
        processRunner: any ProcessRunner = SystemProcessRunner()
    ) {
        self.reader = reader
        self.processRunner = processRunner
    }

    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [
            SystemOverviewProvider(reader: reader),
            SystemStorageProvider(reader: reader),
            SystemProcessProvider(processRunner: processRunner)
        ]
    }
}
