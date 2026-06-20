import XCTest
@testable import GLiNetCore

final class RouterStatusParsingTests: XCTestCase {
    func testParsesLiveSystemStatusShape() {
        let payload: JSONObject = [
            "system": .object([
                "lan_ip": .string("192.168.8.1"),
                "uptime": .number(5103.96)
            ]),
            "network": .array([
                .object(["interface": .string("wan"), "up": .bool(false), "online": .bool(false)]),
                .object(["interface": .string("tethering"), "up": .bool(true), "online": .bool(true)])
            ])
        ]

        let status = RouterStatus(payload: payload)

        XCTAssertTrue(status.reachable)
        XCTAssertEqual(status.activeWAN, .tethering)
        XCTAssertEqual(status.lanIP, "192.168.8.1")
    }
}
