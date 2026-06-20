import XCTest
@testable import AmbitCore

final class ProviderMetricFormatTests: XCTestCase {
    func testFormatsMetricValuesConsistentlyForProviderDisplays() {
        XCTAssertEqual(ProviderMetricFormat.string(.throughput(bitsPerSecond: 12_500_000)), "12.50 Mbps")
        XCTAssertEqual(ProviderMetricFormat.string(.latency(ms: 42.25)), "42.25 ms")
        XCTAssertEqual(ProviderMetricFormat.string(.percent(2.5)), "2.5%")
        XCTAssertEqual(ProviderMetricFormat.string(.level(81)), "81")
        XCTAssertEqual(ProviderMetricFormat.string(.bool(true)), "Yes")
        XCTAssertEqual(ProviderMetricFormat.string(.bool(false)), "No")
        XCTAssertEqual(ProviderMetricFormat.string(.text("connected")), "connected")
    }

    func testFormatsLevelAsPercentWhenMetricIDIndicatesPercent() {
        let metric = Metric(id: "battery_percent", label: "Battery", value: .level(81))

        XCTAssertEqual(ProviderMetricFormat.string(metric), "81%")
    }
}
