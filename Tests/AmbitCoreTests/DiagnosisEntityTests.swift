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
}
