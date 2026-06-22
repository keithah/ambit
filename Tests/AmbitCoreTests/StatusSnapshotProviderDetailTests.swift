import Foundation
import XCTest
@testable import AmbitCore

final class StatusSnapshotProviderDetailTests: XCTestCase {
    func testTypedProviderDetailsReadFromProviderMap() {
        let speedify = SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected", server: "Seattle")
        let starlink = StarlinkStatus(isReachable: true, state: "Online", popPingLatencyMs: 34)
        let ping = PingSnapshot(host: "1.1.1.1", averageLatencyMs: 12.3)
        let iperf3 = Iperf3Snapshot(host: "iperf.example", downloadBps: 10_000_000, uploadBps: 8_000_000)
        let ecoflow = EcoFlowSnapshot(
            status: EcoFlowDeviceStatus(
                battery: EcoFlowBatteryStatus(percent: 82, state: .discharging),
                power: EcoFlowPowerStatus(inputWatts: 0, outputWatts: 12, netWatts: -12),
                outputs: EcoFlowOutputMap(
                    ac: EcoFlowOutputStatus(state: .off, watts: 0),
                    dc: EcoFlowOutputStatus(state: .off, watts: 0),
                    usb: EcoFlowOutputStatus(state: .on, watts: 12)
                ),
                updatedAt: "2026-06-19T00:00:00Z"
            )
        )
        let snapshot = StatusSnapshot(providers: [
            ProviderInstanceIDs.speedify: SourceState(value: ProviderSnapshot.speedify(speedify)),
            ProviderInstanceIDs.starlink: SourceState(value: ProviderSnapshot.starlink(starlink)),
            ProviderInstanceIDs.ecoflow: SourceState(value: ProviderSnapshot.ecoFlow(ecoflow)),
            ProviderInstanceIDs.ping: SourceState(value: ProviderSnapshot.ping(ping)),
            ProviderInstanceIDs.iperf3: SourceState(value: ProviderSnapshot.iperf3(iperf3))
        ])

        XCTAssertEqual(snapshot.providerSpeedifyStatus?.server, "Seattle")
        XCTAssertEqual(snapshot.providerStarlinkStatus?.popPingLatencyMs, 34)
        XCTAssertEqual(snapshot.providerEcoFlowSnapshot?.status.battery.percent, 82)
        XCTAssertEqual(snapshot.providerPingSnapshot?.averageLatencyMs, 12.3)
        XCTAssertEqual(snapshot.providerIperf3Snapshot?.downloadBps, 10_000_000)
    }

    func testProviderErrorMessageFallsBackToLegacySourceState() {
        let snapshot = StatusSnapshot(
            starlink: SourceState(errorMessage: "legacy unavailable")
        )

        XCTAssertEqual(snapshot.providerErrorMessage(ProviderIDs.starlink), "legacy unavailable")
    }
}
