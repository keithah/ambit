import XCTest
@testable import AmbitCore

final class DiagnosticsSupportTests: XCTestCase {
    func testRecentFailuresQueryMapsPingAndNonPingFailedSamples() {
        let now = Date(timeIntervalSince1970: 1_000)
        let ping = EntityDescriptor(
            id: "ping@1.1.1.1:443/probe.latency_ms",
            instanceID: "ping@1.1.1.1:443/probe",
            name: "Latency",
            kind: .sensor,
            deviceClass: .latency,
            unit: "ms",
            stateClass: .measurement
        )
        let cpu = EntityDescriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: "system@local/overview",
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            unit: "%",
            stateClass: .measurement
        )
        let rows = DiagnosticsFailureQuery.rows(
            descriptors: [ping, cpu],
            samplesByEntity: [
                ping.id: [
                    Sample(timestamp: now.addingTimeInterval(-3), value: 12, ok: true),
                    Sample(timestamp: now.addingTimeInterval(-2), value: nil, ok: false, metadata: "timeout")
                ],
                cpu.id: [
                    Sample(timestamp: now.addingTimeInterval(-1), value: nil, ok: false, metadata: "sensor unavailable")
                ]
            ],
            limit: 8
        )

        XCTAssertEqual(rows.map(\.entityID), [cpu.id, ping.id])
        XCTAssertEqual(rows.map(\.entityName), ["CPU", "Latency"])
        XCTAssertEqual(rows.map(\.reason), ["sensor unavailable", "timeout"])
    }

    func testSoftwareUpdateServiceUnavailableAndConfiguredStates() async {
        let unavailable = UnavailableSoftwareUpdateService()

        let unavailableStatus = await unavailable.status()
        let unavailableCheck = await unavailable.checkNow()
        XCTAssertEqual(unavailableStatus, SoftwareUpdateStatus.unavailable(reason: "Software updates are not configured."))
        XCTAssertEqual(unavailableCheck, SoftwareUpdateCheckResult.unavailable("Software updates are not configured."))

        let configured = StaticSoftwareUpdateService(
            status: .idle,
            feedURLStatus: .configured,
            publicKeyStatus: .configured
        )

        let configuredStatus = await configured.status()
        XCTAssertEqual(configuredStatus, .idle)
        XCTAssertEqual(configured.feedURLStatus, .configured)
        XCTAssertEqual(configured.publicKeyStatus, .configured)
    }
}
