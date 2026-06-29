import XCTest
@testable import AmbitCore

final class MonitoringAlertStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

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

    func testFirstObservationSetsBaselineWithoutFiringThenSustainedOutageAlerts() {
        var machine = MonitoringAlertStateMachine(declarations: declarations(), warmUpCycles: 1)
        let down = member(status: .down)

        let warmup = machine.evaluate(members: [down], diagnosis: healthyDiagnosis(), now: at(0))
        let sustained = machine.evaluate(members: [down], diagnosis: healthyDiagnosis(), now: at(1))

        XCTAssertTrue(warmup.isEmpty)
        XCTAssertEqual(sustained.map(\.ruleID), ["fixture.hostDown.fixture"])
    }

    func testNoAlertsFireDuringWarmupForNetworkDiagnosisOrConnectivityOrNetworkChange() {
        var machine = MonitoringAlertStateMachine(declarations: declarations(), warmUpCycles: 2)

        let status = machine.evaluateNetworkStatus(previous: .connected, current: .notConnected, now: at(0))
        let change = machine.networkChangeEvent(MonitoringNetworkChange(previousGateway: "192.168.1.1", currentGateway: "192.168.8.1"), now: at(0))
        let first = machine.evaluate(members: [], diagnosis: networkDiagnosis(.upstreamDown, confidence: .high), now: at(0))
        let second = machine.evaluate(members: [], diagnosis: networkDiagnosis(.upstreamDown, confidence: .high), now: at(1))

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertNil(status)
        XCTAssertNil(change)
    }

    func testSingleCycleDegradedBlipDoesNotFireButSustainedDegradedDoesOnceAndCooldownApplies() {
        var blip = MonitoringAlertStateMachine(declarations: declarations(), networkCooldown: 300, pathDegradedConsecutive: 3, warmUpCycles: 0)
        XCTAssertTrue(blip.evaluate(members: [], diagnosis: networkDiagnosis(.partialDegradation, confidence: .tentative), now: at(0)).isEmpty)
        XCTAssertTrue(blip.evaluate(members: [], diagnosis: healthyDiagnosis(), now: at(1)).isEmpty)

        var sustained = MonitoringAlertStateMachine(declarations: declarations(), networkCooldown: 300, pathDegradedConsecutive: 3, warmUpCycles: 0)
        XCTAssertTrue(sustained.evaluate(members: [], diagnosis: networkDiagnosis(.partialDegradation, confidence: .tentative), now: at(0)).isEmpty)
        XCTAssertTrue(sustained.evaluate(members: [], diagnosis: networkDiagnosis(.partialDegradation, confidence: .tentative), now: at(1)).isEmpty)
        let fired = sustained.evaluate(members: [], diagnosis: networkDiagnosis(.partialDegradation, confidence: .tentative), now: at(2))
        let suppressed = sustained.evaluate(members: [], diagnosis: networkDiagnosis(.partialDegradation, confidence: .tentative), now: at(30))

        XCTAssertEqual(fired.map(\.ruleID), ["ping.pathDegraded"])
        XCTAssertTrue(suppressed.isEmpty)
    }

    func testRecoveryOnlyAfterDeliveredActiveAlert() {
        var machine = MonitoringAlertStateMachine(declarations: declarations(), warmUpCycles: 1)

        let warmupActive = machine.evaluate(members: [], diagnosis: networkDiagnosis(.upstreamDown, confidence: .high), now: at(0))
        let recoveryAfterSuppressedActive = machine.evaluate(members: [], diagnosis: healthyDiagnosis(), now: at(1))
        let deliveredActive = machine.evaluate(members: [], diagnosis: networkDiagnosis(.upstreamDown, confidence: .high), now: at(301))
        let recoveryAfterDeliveredActive = machine.evaluate(members: [], diagnosis: healthyDiagnosis(), now: at(302))

        XCTAssertTrue(warmupActive.isEmpty)
        XCTAssertTrue(recoveryAfterSuppressedActive.isEmpty)
        XCTAssertEqual(deliveredActive.map(\.ruleID), ["ping.upstreamDown"])
        XCTAssertEqual(recoveryAfterDeliveredActive.map(\.ruleID), ["ping.pathRecovered"])
    }

    func testNetworkStatusRecoveryOnlyAfterDeliveredActive() {
        var machine = MonitoringAlertStateMachine(declarations: declarations(), warmUpCycles: 1)

        let suppressedActive = machine.evaluateNetworkStatus(previous: .connected, current: .notConnected, now: at(0))
        _ = machine.evaluate(members: [], diagnosis: healthyDiagnosis(), now: at(0))
        let recoveryAfterSuppressedActive = machine.evaluateNetworkStatus(previous: .notConnected, current: .connected, now: at(1))
        let deliveredActive = machine.evaluateNetworkStatus(previous: .connected, current: .notConnected, now: at(301))
        let recoveryAfterDeliveredActive = machine.evaluateNetworkStatus(previous: .notConnected, current: .connected, now: at(302))

        XCTAssertNil(suppressedActive)
        XCTAssertNil(recoveryAfterSuppressedActive)
        XCTAssertEqual(deliveredActive?.ruleID, "network.status.notConnected")
        XCTAssertEqual(recoveryAfterDeliveredActive?.ruleID, "network.status.recovered")
    }

    func testRealOutageStillAlertsAfterWarmup() {
        var machine = MonitoringAlertStateMachine(declarations: declarations(), warmUpCycles: 1)
        let downMembers = [
            member(id: "one", name: "One", status: .down),
            member(id: "two", name: "Two", status: .down)
        ]

        XCTAssertTrue(machine.evaluate(members: downMembers, diagnosis: healthyDiagnosis(), now: at(0)).isEmpty)
        let fired = machine.evaluate(members: downMembers, diagnosis: healthyDiagnosis(), now: at(1))

        XCTAssertEqual(fired.map(\.ruleID), ["ping.internetLoss"])
    }

    private func at(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    private func declarations() -> [AlertKindDeclaration] {
        [
            AlertKindDeclaration(
                id: "fixture.hostDown",
                titleTemplate: "{hostName} is down",
                messageTemplate: "No response from {hostName}.",
                severity: .critical,
                defaultEnabled: true,
                target: .entity("fixture/status"),
                trigger: .healthTransition(to: .down),
                recovery: AlertRecoveryDeclaration(
                    titleTemplate: "{hostName} recovered",
                    messageTemplate: "{hostName} is reachable again."
                ),
                cooldown: 60
            )
        ]
    }

    private func member(id: String = "fixture", name: String = "Fixture WAN", status: HealthStatus) -> MonitoringAlertMember {
        MonitoringAlertMember(
            id: id,
            name: name,
            status: status,
            target: .entity(EntityID(rawValue: "\(id)/status")),
            notifyOnRecovery: true,
            cooldown: 60
        )
    }

    private func healthyDiagnosis() -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: "fixture.wan",
            verdict: MonitoringVerdict(kind: .allReachable),
            severity: .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: "All reachable",
            detail: "All monitored endpoints are reachable."
        )
    }

    private func networkDiagnosis(_ kind: MonitoringVerdict.Kind, confidence: DiagnosisConfidence) -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: "fixture.wan",
            verdict: MonitoringVerdict(kind: kind, affectedRole: kind == .partialDegradation ? .upstreamInternet : .upstreamInternet),
            severity: DiagnosticSummaryEntity.severity(for: kind) ?? .normal,
            confidence: confidence,
            affectedEntityIDs: [],
            title: "Network issue",
            detail: "Network issue detail."
        )
    }
}
