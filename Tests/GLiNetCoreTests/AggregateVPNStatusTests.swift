import XCTest
@testable import GLiNetCore

final class AggregateVPNStatusTests: XCTestCase {
    func testIncludesSpeedifyAlongsideRouterVPNServices() {
        let speedify = SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected", server: "United States - Seattle #13")
        let routerVPN = VPNStatus(protocol: .vpnClient, isConnected: false, profile: "Primary Tunnel")

        let overview = AggregateVPNStatus(routerVPN: routerVPN, speedify: speedify)

        XCTAssertEqual(overview.services.map(\.label), ["Router VPN Client", "Speedify"])
        XCTAssertEqual(overview.services.map(\.state), ["Disconnected", "Connected"])
        XCTAssertEqual(overview.activeSummary, "Speedify")
        XCTAssertEqual(overview.services[1].server, "United States - Seattle #13")
    }

    func testReportsMultipleActiveVPNsWhenTheyAreStacked() {
        let speedify = SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Disconnected")
        let routerVPN = VPNStatus(protocol: .vpnClient, isConnected: true, profile: "Primary Tunnel")

        let overview = AggregateVPNStatus(routerVPN: routerVPN, speedify: speedify)

        XCTAssertEqual(overview.activeSummary, "Router VPN Client")
        XCTAssertEqual(overview.connectedServices.map(\.label), ["Router VPN Client"])
    }
}
