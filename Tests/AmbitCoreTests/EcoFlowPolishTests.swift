import XCTest
@testable import AmbitCore

final class EcoFlowPolishTests: XCTestCase {
    private func snapshot(minutesRemaining: Int?) -> EcoFlowSnapshot {
        EcoFlowSnapshot(
            status: EcoFlowDeviceStatus(
                battery: EcoFlowBatteryStatus(percent: 82, state: .discharging),
                power: EcoFlowPowerStatus(inputWatts: 0, outputWatts: 12, netWatts: -12),
                outputs: EcoFlowOutputMap(
                    ac: EcoFlowOutputStatus(state: .on, watts: 12),
                    dc: EcoFlowOutputStatus(state: .off, watts: 0),
                    usb: EcoFlowOutputStatus(state: .off, watts: 0)
                ),
                updatedAt: "2026-06-22T00:00:00Z"
            ),
            stats: minutesRemaining.map {
                EcoFlowDeviceStats(
                    batteryPercent: nil, inputWatts: nil, outputWatts: nil, netWatts: nil,
                    estimatedMinutesRemaining: $0, estimatedMinutesToFull: nil,
                    isEstimateDerived: false, updatedAt: "2026-06-22T00:00:00Z"
                )
            }
        )
    }

    func testEmitsTimeRemainingMetricFromStats() {
        let snapshot = ProviderSnapshot.ecoFlow(snapshot(minutesRemaining: 120))
        XCTAssertEqual(snapshot.metric("time_remaining")?.value, .level(120))
        XCTAssertEqual(snapshot.metric("time_remaining")?.deviceClass, .duration)
        XCTAssertEqual(snapshot.metric("output_watts")?.deviceClass, .power)
    }

    func testNoTimeRemainingMetricWhenStatsAbsent() {
        let snapshot = ProviderSnapshot.ecoFlow(snapshot(minutesRemaining: nil))
        XCTAssertNil(snapshot.metric("time_remaining"))
    }

    func testDescriptorsIncludeOutputWattsAndTimeRemaining() {
        let byID = Dictionary(uniqueKeysWithValues: EcoFlowProvider().entityDescriptors().map { ($0.id.rawValue, $0) })
        XCTAssertEqual(byID["ecoflow/ecoflow.output_watts"]?.deviceClass, .power)
        XCTAssertEqual(byID["ecoflow/ecoflow.time_remaining"]?.deviceClass, .duration)
        XCTAssertEqual(byID["ecoflow/ecoflow.time_remaining"]?.unit, "min")
    }
}
