import Foundation

public protocol SystemMetricsReading: Sendable {
    func snapshot() async throws -> SystemMetricsSnapshot
}
