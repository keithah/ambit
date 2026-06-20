import Foundation
import XCTest
@testable import AmbitCore

final class StatusSnapshotProviderDetailTests: XCTestCase {
    func testTypedProviderDetailsReadFromProviderMap() {
        let speedify = SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected", server: "Seattle")
        let starlink = StarlinkStatus(isReachable: true, state: "Online", popPingLatencyMs: 34)
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
            ProviderIDs.speedify: SourceState(value: ProviderSnapshot.speedify(speedify)),
            ProviderIDs.starlink: SourceState(value: ProviderSnapshot.starlink(starlink)),
            ProviderIDs.ecoflow: SourceState(value: ProviderSnapshot.ecoFlow(ecoflow))
        ])

        XCTAssertEqual(snapshot.providerSpeedifyStatus?.server, "Seattle")
        XCTAssertEqual(snapshot.providerStarlinkStatus?.popPingLatencyMs, 34)
        XCTAssertEqual(snapshot.providerEcoFlowSnapshot?.status.battery.percent, 82)
    }

    func testProviderErrorMessageFallsBackToLegacySourceState() {
        let snapshot = StatusSnapshot(
            starlink: SourceState(errorMessage: "legacy unavailable")
        )

        XCTAssertEqual(snapshot.providerErrorMessage(ProviderIDs.starlink), "legacy unavailable")
    }
}
