import XCTest
@testable import AmbitCore
@testable import AmbitMenuBar

final class LocalNetworkPrivacyHintTests: XCTestCase {
    func testRequiresLocalNetworkPermissionForPrivateLinkLocalAndLoopbackHosts() {
        XCTAssertTrue(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "192.168.8.1"))
        XCTAssertTrue(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "10.0.0.1"))
        XCTAssertTrue(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "172.16.0.1"))
        XCTAssertTrue(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "169.254.1.1"))
        XCTAssertTrue(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "127.0.0.1"))
        XCTAssertTrue(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "localhost"))
    }

    func testDoesNotRequireLocalNetworkPermissionForPublicHosts() {
        XCTAssertFalse(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "1.1.1.1"))
        XCTAssertFalse(LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: "example.com"))
    }

    @MainActor
    func testStatusViewModelListsLocalNetworkPermissionHintsForLocalPingHosts() {
        let gateway = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Gateway", address: "192.168.8.1", method: .icmp))
        let publicHost = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Cloudflare", address: "1.1.1.1", method: .tcp, port: 443))

        let hints = StatusViewModel.localNetworkPermissionHints(records: [gateway, publicHost])

        XCTAssertEqual(hints.map(\.title), ["Gateway"])
    }
}
