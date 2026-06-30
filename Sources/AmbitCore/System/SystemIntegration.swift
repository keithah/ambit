import Foundation

public struct SystemIntegration: Integration {
    public let id = IntegrationIDs.system
    public let displayName = "System"

    private let reader: any SystemMetricsReading
    private let processRunner: any ProcessRunner
    private let sensorReader: any SystemSensorReading
    private let networkInfoReader: any SystemNetworkInfoReading
    private let calendarReader: any SystemCalendarReading
    private let locationReader: any SystemLocationReading
    private let placeStore: any PlaceStore
    private let focusReader: any SystemFocusReading

    public init(
        reader: any SystemMetricsReading = DarwinSystemMetricsReader(),
        processRunner: any ProcessRunner = SystemProcessRunner(),
        sensorReader: any SystemSensorReading = NoOpSystemSensorReader(),
        networkInfoReader: any SystemNetworkInfoReading = DarwinSystemNetworkInfoReader(),
        calendarReader: any SystemCalendarReading = DarwinSystemCalendarReader(),
        locationReader: any SystemLocationReading = DarwinSystemLocationReader(),
        placeStore: any PlaceStore = UserDefaultsPlaceStore(),
        focusReader: any SystemFocusReading = NoOpSystemFocusReader()
    ) {
        self.reader = reader
        self.processRunner = processRunner
        self.sensorReader = sensorReader
        self.networkInfoReader = networkInfoReader
        self.calendarReader = calendarReader
        self.locationReader = locationReader
        self.placeStore = placeStore
        self.focusReader = focusReader
    }

    public func makeProviders(instance: IntegrationInstanceRecord) -> [any Provider] {
        [
            SystemOverviewProvider(reader: reader),
            SystemStorageProvider(reader: reader),
            SystemProcessProvider(processRunner: processRunner),
            SystemNetworkProvider(reader: reader, networkInfoReader: networkInfoReader),
            SystemSensorProvider(reader: sensorReader),
            SystemFanProvider(reader: sensorReader),
            SystemCalendarProvider(reader: calendarReader),
            SystemLocationProvider(reader: locationReader, placeStore: placeStore),
            SystemFocusProvider(reader: focusReader)
        ]
    }
}
