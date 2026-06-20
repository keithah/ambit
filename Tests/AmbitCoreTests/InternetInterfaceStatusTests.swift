import XCTest
@testable import AmbitCore

final class InternetInterfaceStatusTests: XCTestCase {
    func testBuildsOverviewInterfacesFromRouterAndSpeedifyStatus() {
        let router = RouterStatus(reachable: true, activeWAN: .modem)
        let speedify = SpeedifyStatus(
            isInstalled: true,
            isAvailable: true,
            isConnected: true,
            state: "Connected",
            networks: [
                SpeedifyNetwork(id: "rmnet_mhi0", name: "rmnet_mhi0", type: "Cellular", isp: "T-Mobile USA", priority: .always, receiveBps: 150_000, sendBps: 52_000),
                SpeedifyNetwork(id: "eth0", name: "eth0", type: "Ethernet", isp: "Starlink", priority: .secondary, receiveBps: 37_000, sendBps: 66_000, statusMessage: "Multiple issues detected")
            ]
        )

        let interfaces = InternetInterfaceStatus.overview(router: router, speedify: speedify)

        XCTAssertEqual(interfaces.map(\.kind), [.cellular, .starlink, .tethering])
        XCTAssertEqual(interfaces[0].label, "Cellular")
        XCTAssertEqual(interfaces[0].detail, "T-Mobile USA")
        XCTAssertTrue(interfaces[0].isPrimary)
        XCTAssertEqual(interfaces[1].label, "Starlink")
        XCTAssertEqual(interfaces[1].qualityLabel, "Multiple issues detected")
        XCTAssertFalse(interfaces[2].isConnected)
    }

    func testTopologyPromotesReachableStarlinkOverGenericEthernetWAN() {
        let router = RouterStatus(reachable: true, activeWAN: .wired)
        let starlink = StarlinkStatus(
            isReachable: true,
            state: "Online",
            downlinkThroughputBps: 58_000,
            uplinkThroughputBps: 12_000
        )

        let interfaces = InternetInterfaceStatus.topology(router: router, speedify: nil, starlink: starlink)

        XCTAssertEqual(interfaces.map(\.kind), [.starlink, .tethering])
        XCTAssertEqual(interfaces[0].label, "Starlink")
        XCTAssertEqual(interfaces[0].detail, "Ethernet")
        XCTAssertEqual(interfaces[0].qualityLabel, "Online")
        XCTAssertEqual(interfaces[0].downloadBps, 58_000)
    }

    func testOverviewDoesNotMarkOfflineSpeedifyEthernetAsActive() {
        let speedify = SpeedifyStatus(
            isInstalled: true,
            isAvailable: true,
            isConnected: true,
            state: "Connected",
            networks: [
                SpeedifyNetwork(id: "rmnet_mhi0", name: "rmnet_mhi0", type: "Cellular", isp: "T-Mobile USA", priority: .always, isConnected: true),
                SpeedifyNetwork(id: "eth0", name: "eth0", type: "Ethernet", priority: .secondary, isConnected: false)
            ]
        )

        let interfaces = InternetInterfaceStatus.overview(router: nil, speedify: speedify)

        XCTAssertTrue(interfaces.first { $0.kind == .cellular }?.isConnected == true)
        XCTAssertTrue(interfaces.first { $0.kind == .ethernet }?.isConnected == false)
    }
}
