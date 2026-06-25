import XCTest
@testable import AmbitCore

final class SystemSensorProviderTests: XCTestCase {
    func testNoOpSystemSensorReaderProducesUnavailableStatesWithoutThrowing() async {
        let sensorProvider = SystemSensorProvider(reader: NoOpSystemSensorReader())
        let fanProvider = SystemFanProvider(reader: NoOpSystemSensorReader())

        let sensorSnapshot = await sensorProvider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let fanSnapshot = await fanProvider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let sensorStates = EntityProjection.states(snapshot: sensorSnapshot, descriptors: sensorProvider.entityDescriptors())
        let fanStates = EntityProjection.states(snapshot: fanSnapshot, descriptors: fanProvider.entityDescriptors())

        XCTAssertFalse(NoOpSystemSensorReader().isAvailable)
        XCTAssertEqual(sensorProvider.entityDescriptors().first?.capability, "system.sensors")
        XCTAssertEqual(fanProvider.entityDescriptors().first?.capability, "system.fans")
        XCTAssertEqual(sensorProvider.entityDescriptors().first?.defaultVisibility, .never)
        XCTAssertEqual(fanProvider.entityDescriptors().first?.defaultVisibility, .never)
        XCTAssertTrue(sensorStates.values.allSatisfy { $0.availability == .unavailable })
        XCTAssertTrue(fanStates.values.allSatisfy { $0.availability == .unavailable })
        XCTAssertNil(sensorSnapshot.error)
        XCTAssertNil(fanSnapshot.error)
    }

    func testFakeSensorSnapshotEmitsTemperatureAndFanEntitiesInCorrectSections() async {
        let reader = FakeSystemSensorReader(snapshot: SystemSensorSnapshot(
            temperatures: [
                TemperatureSensorMetrics(name: "CPU Proximity", celsius: 57.5),
                TemperatureSensorMetrics(name: "GPU Die", celsius: 62)
            ],
            fans: [
                FanSpeedMetrics(name: "Left Fan", rpm: 2_100),
                FanSpeedMetrics(name: "Right Fan", rpm: 2_250)
            ]
        ))
        let sensorProvider = SystemSensorProvider(reader: reader, temperatureNames: ["CPU Proximity", "GPU Die"])
        let fanProvider = SystemFanProvider(reader: reader)

        let sensorSnapshot = await sensorProvider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let fanSnapshot = await fanProvider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(sensorSnapshot.metricValue("temperature.cpu_proximity"), .level(57.5))
        XCTAssertEqual(sensorSnapshot.metricValue("temperature.gpu_die"), .level(62))
        XCTAssertEqual(sensorProvider.entityDescriptors().map(\.defaultVisibility), [.auto, .auto])
        XCTAssertEqual(fanProvider.entityDescriptors().first?.defaultVisibility, .auto)
        guard case .table(let fanTable) = fanSnapshot.metricValue("fans") else {
            return XCTFail("Expected fans table")
        }
        XCTAssertEqual(fanTable.rows.map(\.id), ["Left Fan", "Right Fan"])
        XCTAssertEqual(fanTable.rows[0].cells["rpm"], .number(2_100, unit: "rpm"))

        let plan = SurfaceComposer.detailPlan(
            descriptors: sensorProvider.entityDescriptors() + fanProvider.entityDescriptors(),
            states: [:]
        )
        XCTAssertEqual(plan.cards.map(\.title), ["Sensors", "Fans"])
    }

    func testSystemIntegrationWiresSensorAndFanProviders() {
        let integration = SystemIntegration(
            reader: FakeSystemMetricsReader(snapshot: Self.metricsSnapshot()),
            processRunner: FakeSensorProcessRunner(),
            sensorReader: NoOpSystemSensorReader()
        )

        let providers = integration.makeProviders(instance: IntegrationInstanceRecord(
            id: IntegrationInstanceIDs.systemLocal,
            integrationID: IntegrationIDs.system,
            displayName: "System",
            enabled: true,
            origin: .builtIn
        ))

        XCTAssertTrue(providers.map(\.id).contains(ProviderIDs.systemSensors))
        XCTAssertTrue(providers.map(\.id).contains(ProviderIDs.systemFans))
    }

    private static func metricsSnapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 0, systemPercent: 0, idlePercent: 100, coreCount: 1),
            memory: MemoryMetrics(usedBytes: 0, wiredBytes: 0, compressedBytes: 0, totalBytes: 1)
        )
    }
}

private struct FakeSystemSensorReader: SystemSensorReading {
    var snapshot: SystemSensorSnapshot
    var isAvailable: Bool { true }
    func snapshot() async throws -> SystemSensorSnapshot { snapshot }
}

private struct FakeSystemMetricsReader: SystemMetricsReading {
    var snapshot: SystemMetricsSnapshot
    func snapshot() async throws -> SystemMetricsSnapshot { snapshot }
}

private struct FakeSensorProcessRunner: ProcessRunner {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}
