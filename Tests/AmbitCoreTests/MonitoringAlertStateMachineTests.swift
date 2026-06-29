import XCTest
@testable import AmbitCore

final class MonitoringAlertStateMachineTests: XCTestCase {
    func testNonPingFixtureEmitsActiveAndRecoveryAlertsThroughDeclarations() {
        var machine = MonitoringAlertStateMachine(declarations: [
            AlertKindDeclaration(
                id: "fixture.wanDown",
                titleTemplate: "{hostName} is down",
                messageTemplate: "No response from {hostName}.",
                severity: .critical,
                defaultEnabled: true,
                target: .entity("fixture@local/wan.status"),
                trigger: .healthTransition(to: .down),
                recovery: AlertRecoveryDeclaration(
                    titleTemplate: "{hostName} recovered",
                    messageTemplate: "{hostName} is reachable again."
                ),
                cooldown: 60
            )
        ])
        let healthy = MonitoringAlertMember(
            id: "fixture@local",
            name: "Fixture WAN",
            status: .healthy,
            target: .entity("fixture@local/wan.status"),
            notifyOnRecovery: true,
            cooldown: 60
        )
        let down = MonitoringAlertMember(
            id: "fixture@local",
            name: "Fixture WAN",
            status: .down,
            target: .entity("fixture@local/wan.status"),
            notifyOnRecovery: true,
            cooldown: 60
        )
        let diagnosis = MonitoringDiagnosis(
            perspectiveID: "fixture.wan",
            verdict: MonitoringVerdict(kind: .allReachable),
            severity: .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: "All reachable",
            detail: "1/1 monitored hosts healthy."
        )

        _ = machine.evaluate(members: [healthy], diagnosis: diagnosis, now: Date(timeIntervalSince1970: 0))
        let active = machine.evaluate(members: [down], diagnosis: diagnosis, now: Date(timeIntervalSince1970: 1))
        let recovered = machine.evaluate(members: [healthy], diagnosis: diagnosis, now: Date(timeIntervalSince1970: 70))

        XCTAssertEqual(active.map(\.ruleID), ["fixture.wanDown.fixture@local"])
        XCTAssertEqual(active.first?.target, .entity("fixture@local/wan.status"))
        XCTAssertEqual(active.first?.title, "Fixture WAN is down")
        XCTAssertEqual(recovered.map(\.ruleID), ["fixture.wanDown.recovered.fixture@local"])
        XCTAssertEqual(recovered.map(\.phase), [.recovered])
        XCTAssertEqual(recovered.first?.title, "Fixture WAN recovered")
    }
}
