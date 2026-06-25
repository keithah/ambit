import Foundation

public struct SystemIntegration: Integration {
    public let id = IntegrationIDs.system
    public let displayName = "System"

    private let reader: any SystemMetricsReading

    public init(reader: any SystemMetricsReading = DarwinSystemMetricsReader()) {
        self.reader = reader
    }

    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [SystemOverviewProvider(reader: reader)]
    }
}
