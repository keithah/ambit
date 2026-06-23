import XCTest
@testable import AmbitCore

final class NetworkDiagnosisTests: XCTestCase {
    private let diagnoser = NetworkPerspectiveDiagnoser()
    private func host(_ id: String, _ tier: NetworkTier, _ status: HealthStatus, failures: Int = 0) -> DiagnosisHost {
        DiagnosisHost(id: id, tier: tier, status: status, consecutiveFailures: failures)
    }

    func testAllReachable() {
        let d = diagnoser.diagnose(hosts: [host("gw", .localGateway, .healthy), host("cf", .upstream, .healthy)])
        XCTAssertEqual(d.scope, .allReachable)
        XCTAssertEqual(d.verdict, .allReachable)
        XCTAssertEqual(d.confidence, .high)
        XCTAssertNil(d.faultTier)
    }

    func testPrioritizesGatewayFailureOverRemote() {
        let d = diagnoser.diagnose(hosts: [host("gw", .localGateway, .down), host("cf", .upstream, .down)])
        XCTAssertEqual(d.scope, .localNetwork)
        XCTAssertEqual(d.verdict, .localNetworkDown)
        XCTAssertEqual(d.confidence, .high)
        XCTAssertEqual(d.faultTier, .localGateway)
    }

    func testUpstreamDownWhenLocalHealthy() {
        let d = diagnoser.diagnose(hosts: [host("gw", .localGateway, .healthy), host("cf", .upstream, .down)])
        XCTAssertEqual(d.scope, .upstream)
        XCTAssertEqual(d.verdict, .upstreamDown)
        XCTAssertEqual(d.confidence, .high)
        XCTAssertEqual(d.faultTier, .upstream)
    }

    func testISPEdgeFaultMapsToISPPathDown() {
        let d = diagnoser.diagnose(hosts: [
            host("gw", .localGateway, .healthy), host("dish", .ispEdge, .down), host("cf", .upstream, .down)
        ])
        XCTAssertEqual(d.verdict, .ispPathDown)
        XCTAssertEqual(d.faultTier, .ispEdge)
        XCTAssertEqual(d.scope, .upstream)
    }

    func testIsolatedRemoteServiceDown() {
        let d = diagnoser.diagnose(hosts: [host("cf", .upstream, .healthy), host("svc", .remoteService, .down)])
        XCTAssertEqual(d.scope, .remoteService)
        XCTAssertEqual(d.faultTier, .remoteService)
        if case .remoteServiceDown(let ids) = d.verdict { XCTAssertEqual(ids, ["svc"]) } else { XCTFail("expected remoteServiceDown") }
    }

    func testMixedTierEvidenceIsTentative() {
        let d = diagnoser.diagnose(hosts: [host("cf", .upstream, .down), host("goog", .upstream, .healthy)])
        XCTAssertEqual(d.verdict, .upstreamDown)
        XCTAssertEqual(d.confidence, .tentative)  // 1/2 down
    }

    func testSingleTransientFailureIsPartialDegradationNotDown() {
        let d = diagnoser.diagnose(hosts: [host("cf", .upstream, .degraded, failures: 1)])
        XCTAssertEqual(d.scope, .partialDegradation)
        XCTAssertEqual(d.confidence, .tentative)
        if case .partialDegradation(let tier) = d.verdict { XCTAssertEqual(tier, .upstream) } else { XCTFail("expected partialDegradation") }
    }

    func testNotConnectedSuppressesPathBlame() {
        let d = diagnoser.diagnose(hosts: [host("gw", .localGateway, .down), host("cf", .upstream, .down)], networkStatus: .notConnected)
        XCTAssertEqual(d.verdict, .localNetworkDown)
        XCTAssertEqual(d.faultTier, .localGateway)
        XCTAssertTrue(d.tierEvidence.isEmpty)
    }

    func testNoInternetIsTentativeUpstream() {
        let d = diagnoser.diagnose(hosts: [host("cf", .upstream, .down)], networkStatus: .noInternet)
        XCTAssertEqual(d.verdict, .upstreamDown)
        XCTAssertEqual(d.confidence, .tentative)
    }

    func testNoDataWhenNoObservedHosts() {
        let d = diagnoser.diagnose(hosts: [host("cf", .upstream, .noData)])
        XCTAssertEqual(d.scope, .noData)
    }
}
