import XCTest
@testable import AmbitCore

final class VPNStatusParsingTests: XCTestCase {
    func testParsesConnectedWireGuardPayload() {
        let payload: JSONObject = [
            "status": .string("connected"),
            "endpoint": .string("vpn.example.com:51820"),
            "name": .string("travel"),
            "rx_bytes": .number(1024),
            "tx_bytes": .number(2048)
        ]

        let status = VPNStatus(protocol: .wireGuard, payload: payload)

        XCTAssertEqual(status.vpnProtocol, .wireGuard)
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.server, "vpn.example.com:51820")
        XCTAssertEqual(status.profile, "travel")
        XCTAssertEqual(status.rxBytes, 1024)
        XCTAssertEqual(status.txBytes, 2048)
        XCTAssertTrue(status.isAvailable)
    }

    func testParsesNumericServiceStyleRunningState() {
        let payload: JSONObject = [
            "status": .number(0),
            "running": .bool(false)
        ]

        let status = VPNStatus(protocol: .openVPN, payload: payload)

        XCTAssertEqual(status.vpnProtocol, .openVPN)
        XCTAssertFalse(status.isConnected)
    }
}
