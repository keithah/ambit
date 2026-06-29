import XCTest
@testable import AmbitCore

final class DiagnosisEntityTests: XCTestCase {
    private func diag(_ scope: NetworkPerspectiveDiagnosis.Scope,
                      _ verdict: NetworkPerspectiveDiagnosis.Verdict,
                      title: String = "T", detail: String = "D") -> NetworkPerspectiveDiagnosis {
        .init(scope: scope, verdict: verdict, confidence: .high, faultTier: nil,
              affectedHostIDs: [], title: title, detail: detail, tierEvidence: [])
    }

    func testHealthyAndNoDataOmitTheBanner() {
        XCTAssertNil(DiagnosisEntity.make(diag(.allReachable, .allReachable)))
        XCTAssertNil(DiagnosisEntity.make(diag(.noData, .noData)))
    }

    func testConnectivityLossIsDown() {
        for verdict in [NetworkPerspectiveDiagnosis.Verdict.localNetworkDown, .ispPathDown, .upstreamDown] {
            let made = DiagnosisEntity.make(diag(.upstream, verdict))
            XCTAssertEqual(made?.1.severity, .down, "\(verdict)")
        }
    }

    func testRemoteServiceIsAlertingAndPartialIsDegraded() {
        XCTAssertEqual(DiagnosisEntity.make(diag(.remoteService, .remoteServiceDown(hostIDs: ["h"])))?.1.severity, .alerting)
        XCTAssertEqual(DiagnosisEntity.make(diag(.partialDegradation, .partialDegradation(tier: .ispEdge)))?.1.severity, .degraded)
    }

    func testEntityCarriesTitleAndDetail() {
        let made = DiagnosisEntity.make(diag(.localNetwork, .localNetworkDown, title: "Local network down", detail: "1/1 gateway host(s) unreachable."))
        XCTAssertEqual(made?.0.id, DiagnosisEntity.entityID)
        XCTAssertEqual(made?.0.name, "Local network down")
        XCTAssertEqual(made?.0.kind, .text)
        XCTAssertEqual(made?.0.category, .diagnostic)
        XCTAssertEqual(made?.1.value, .text("1/1 gateway host(s) unreachable."))
        XCTAssertEqual(made?.1.availability, .online)
    }

    func testGenericSummaryPreservesLegacyPingEntityID() {
        let diagnosis = MonitoringDiagnosis(
            perspectiveID: "ping.default",
            verdict: MonitoringVerdict(kind: .localNetworkDown, affectedRole: .localGateway),
            severity: .down,
            confidence: .high,
            affectedEntityIDs: [],
            title: "Local network down",
            detail: "1/1 gateway host(s) unreachable."
        )

        let made = DiagnosticSummaryEntity.make(diagnosis, owner: .ping)

        XCTAssertEqual(made?.0.id, DiagnosisEntity.entityID)
        XCTAssertEqual(made?.0.instanceID, DiagnosisEntity.instanceID)
        XCTAssertEqual(made?.0.category, .diagnostic)
        XCTAssertEqual(made?.1.id, DiagnosisEntity.entityID)
        XCTAssertEqual(made?.1.value, .text("1/1 gateway host(s) unreachable."))
    }

    func testGenericSummarySupportsNonPingOwner() {
        let diagnosis = MonitoringDiagnosis(
            perspectiveID: "fixture.wan",
            verdict: MonitoringVerdict(kind: .upstreamDown, affectedRole: .upstreamInternet),
            severity: .down,
            confidence: .high,
            affectedEntityIDs: ["fixture@local/wan.status"],
            title: "Internet unreachable",
            detail: "1/1 upstream host(s) unreachable."
        )

        let made = DiagnosticSummaryEntity.make(diagnosis, owner: .custom(instanceID: "fixture.summary", entityID: "fixture.summary.diagnosis"))

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
        XCTAssertEqual(DiagnosticSummaryEntity.Owner.ping.entityID, DiagnosisEntity.entityID)
    }
}
