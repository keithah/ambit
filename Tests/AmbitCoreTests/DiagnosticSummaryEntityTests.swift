import XCTest
@testable import AmbitCore

final class DiagnosticSummaryEntityTests: XCTestCase {
    func testHealthyAndNoDataOmitTheBanner() {
        XCTAssertNil(DiagnosticSummaryEntity.make(diagnosis(.allReachable), owner: .ping))
        XCTAssertNil(DiagnosticSummaryEntity.make(diagnosis(.noData), owner: .ping))
    }

    func testConnectivityLossIsDown() {
        for verdict in [MonitoringVerdict.Kind.localNetworkDown, .accessNetworkDown, .upstreamDown] {
            let made = DiagnosticSummaryEntity.make(diagnosis(verdict), owner: .ping)
            XCTAssertEqual(made?.1.severity, .down, "\(verdict)")
        }
    }

    func testRemoteServiceIsAlertingAndPartialIsDegraded() {
        XCTAssertEqual(DiagnosticSummaryEntity.make(diagnosis(.remoteServiceDown), owner: .ping)?.1.severity, .alerting)
        XCTAssertEqual(DiagnosticSummaryEntity.make(diagnosis(.partialDegradation), owner: .ping)?.1.severity, .degraded)
    }

    func testEntityCarriesTitleAndDetail() {
        let made = DiagnosticSummaryEntity.make(
            diagnosis(.localNetworkDown, title: "Local network down", detail: "1/1 gateway host(s) unreachable."),
            owner: .ping
        )
        XCTAssertEqual(made?.0.id, DiagnosticSummaryEntity.Owner.ping.entityID)
        XCTAssertEqual(made?.0.name, "Local network down")
        XCTAssertEqual(made?.0.kind, .text)
        XCTAssertEqual(made?.0.category, .diagnostic)
        XCTAssertEqual(made?.1.value, .text("1/1 gateway host(s) unreachable."))
        XCTAssertEqual(made?.1.availability, .online)
    }

    func testGenericSummaryPreservesPingSummaryEntityID() {
        let made = DiagnosticSummaryEntity.make(
            diagnosis(.localNetworkDown, title: "Local network down", detail: "1/1 gateway host(s) unreachable."),
            owner: .ping
        )

        XCTAssertEqual(made?.0.id, "ping.summary.diagnosis")
        XCTAssertEqual(made?.0.instanceID, "ping.summary")
        XCTAssertEqual(made?.0.category, .diagnostic)
        XCTAssertEqual(made?.1.id, "ping.summary.diagnosis")
        XCTAssertEqual(made?.1.value, .text("1/1 gateway host(s) unreachable."))
    }

    func testGenericSummarySupportsNonPingOwner() {
        let made = DiagnosticSummaryEntity.make(
            diagnosis(.upstreamDown, title: "Internet unreachable", detail: "1/1 upstream host(s) unreachable."),
            owner: .custom(instanceID: "fixture.summary", entityID: "fixture.summary.diagnosis")
        )

        XCTAssertEqual(made?.0.id, "fixture.summary.diagnosis")
        XCTAssertEqual(made?.0.instanceID, "fixture.summary")
        XCTAssertEqual(made?.0.kind, .text)
        XCTAssertEqual(made?.0.category, .diagnostic)
        XCTAssertEqual(made?.1.severity, .down)
    }

    func testPreMilestoneFixtureSummaryOverrideContinuesToResolveToPingSummaryID() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("GenericMonitoringParity")
            .appendingPathComponent("observable_ping_surface.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(fixture.contains(DiagnosticSummaryEntity.Owner.ping.entityID.rawValue))
        XCTAssertEqual(DiagnosticSummaryEntity.Owner.ping.entityID, "ping.summary.diagnosis")
    }

    private func diagnosis(
        _ verdict: MonitoringVerdict.Kind,
        title: String = "T",
        detail: String = "D"
    ) -> MonitoringDiagnosis {
        MonitoringDiagnosis(
            perspectiveID: "monitoring.default",
            verdict: MonitoringVerdict(kind: verdict, affectedRole: affectedRole(for: verdict)),
            severity: DiagnosticSummaryEntity.severity(for: verdict) ?? .normal,
            confidence: .high,
            affectedEntityIDs: [],
            title: title,
            detail: detail
        )
    }

    private func affectedRole(for verdict: MonitoringVerdict.Kind) -> MonitoringRole? {
        switch verdict {
        case .localNetworkDown: return .localGateway
        case .accessNetworkDown: return .accessNetwork
        case .upstreamDown: return .upstreamInternet
        case .remoteServiceDown: return .remoteService
        case .partialDegradation: return .upstreamInternet
        case .noData, .monitoringStalled, .allReachable: return nil
        }
    }
}
