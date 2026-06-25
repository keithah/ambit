import Foundation

public protocol SystemSensorReading: Sendable {
    var isAvailable: Bool { get }
    func snapshot() async throws -> SystemSensorSnapshot
}

public struct SystemSensorSnapshot: Equatable, Sendable, Codable {
    public var temperatures: [TemperatureSensorMetrics]
    public var fans: [FanSpeedMetrics]

    public init(temperatures: [TemperatureSensorMetrics] = [], fans: [FanSpeedMetrics] = []) {
        self.temperatures = temperatures
        self.fans = fans
    }
}

public struct TemperatureSensorMetrics: Equatable, Sendable, Codable {
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct FanSpeedMetrics: Equatable, Sendable, Codable {
    public var name: String
    public var rpm: Double

    public init(name: String, rpm: Double) {
        self.name = name
        self.rpm = rpm
    }
}

public struct SensorUnavailableError: Error, Equatable, Sendable {
    public init() {}
}

public struct NoOpSystemSensorReader: SystemSensorReading {
    public var isAvailable: Bool { false }

    public init() {}

    public func snapshot() async throws -> SystemSensorSnapshot {
        throw SensorUnavailableError()
    }
}
