import XCTest
@testable import AmbitCore

final class TopologyDiagnosisEngineTests: XCTestCase {
    func testLocalLinkStatusOverrideWinsOverMemberSamples() {
        let diagnosis = TopologyDiagnosisEngine().diagnose(MonitoringPerspective(
            id: "test.network",
            title: "Test Network",
            members: [
                member("upstream", role: .upstreamInternet, status: .healthy)
            ],
            linkStatus: .notConnected,
            sensitivity: .balanced
        ))

        XCTAssertEqual(diagnosis.title, "Local network down")
        XCTAssertEqual(diagnosis.verdict.kind, .localNetworkDown)
        XCTAssertEqual(diagnosis.severity, .down)
    }

    func testStaleObservedMembersProduceMonitoringPaused() {
        let diagnosis = TopologyDiagnosisEngine().diagnose(MonitoringPerspective(
            id: "test.network",
            title: "Test Network",
            members: [
                member("upstream", role: .upstreamInternet, status: .healthy, isStale: true)
            ],
            linkStatus: .connected,
            sensitivity: .balanced
        ))

        XCTAssertEqual(diagnosis.title, "Monitoring paused")
        XCTAssertEqual(diagnosis.verdict.kind, .monitoringStalled)
        XCTAssertEqual(diagnosis.severity, .elevated)
    }

    func testNonPingFixtureProducesTopologyDiagnosisWithoutPingTypes() {
        let diagnosis = TopologyDiagnosisEngine().diagnose(MonitoringPerspective(
            id: "fixture.wan",
            title: "Fixture WAN",
            members: [
                member("fixture@local/wan.status", instanceID: "fixture@local", role: .upstreamInternet, status: .down)
            ],
            linkStatus: .connected,
            sensitivity: .balanced
        ))

        XCTAssertEqual(diagnosis.title, "Internet unreachable")
        XCTAssertEqual(diagnosis.verdict.kind, .upstreamDown)
        XCTAssertEqual(diagnosis.affectedEntityIDs, ["fixture@local/wan.status"])
        XCTAssertEqual(diagnosis.evidence.map(\.role), [.upstreamInternet])
    }

    private func member(
        _ id: EntityID,
        instanceID: IntegrationInstanceID? = nil,
        role: MonitoringRole,
        status: HealthStatus,
        isStale: Bool = false
    ) -> MonitoringPerspectiveMember {
        MonitoringPerspectiveMember(
            entityID: id,
            instanceID: instanceID ?? IntegrationInstanceID(rawValue: id.rawValue),
            displayName: id.rawValue,
            role: role,
            status: status,
            isStale: isStale,
            consecutiveFailures: status == .down ? 3 : 0
        )
    }
}
