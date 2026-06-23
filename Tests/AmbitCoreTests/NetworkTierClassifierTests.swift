import XCTest
@testable import AmbitCore

final class NetworkTierClassifierTests: XCTestCase {
    private let classifier = NetworkTierClassifier()
    private func host(_ address: String, tier: NetworkTier? = nil) -> PingScopeHostConfig {
        PingScopeHostConfig(displayName: "H", address: address, method: .icmp, tier: tier)
    }

    func testPrivateAddressesAreLocalGateway() {
        XCTAssertEqual(NetworkTierClassifier.infer(address: "192.168.1.1"), .localGateway)
        XCTAssertEqual(NetworkTierClassifier.infer(address: "10.20.30.40"), .localGateway)
        XCTAssertEqual(NetworkTierClassifier.infer(address: "172.16.0.1"), .localGateway)
        XCTAssertEqual(NetworkTierClassifier.infer(address: "169.254.1.1"), .localGateway)
    }

    func testPublicIPv4IsUpstream() {
        XCTAssertEqual(NetworkTierClassifier.infer(address: "1.1.1.1"), .upstream)
        XCTAssertEqual(NetworkTierClassifier.infer(address: "8.8.8.8"), .upstream)
        XCTAssertEqual(NetworkTierClassifier.infer(address: "203.0.113.1"), .upstream)
    }

    func testHostnameIsRemoteService() {
        XCTAssertEqual(NetworkTierClassifier.infer(address: "example.com"), .remoteService)
        XCTAssertEqual(NetworkTierClassifier.infer(address: "my.host.local"), .remoteService)
    }

    func testExplicitTierOverridesInference() {
        XCTAssertEqual(classifier.tier(for: host("8.8.8.8", tier: .ispEdge)), .ispEdge)
        XCTAssertEqual(classifier.tier(for: host("8.8.8.8")), .upstream)  // no override → inferred
    }

    func testTierDepthOrder() {
        XCTAssertEqual([NetworkTier.localGateway, .ispEdge, .upstream, .remoteService].map(\.depth), [0, 1, 2, 3])
    }
}
