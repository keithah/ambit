import XCTest
@testable import AmbitCore

final class ProviderMetricSectionTests: XCTestCase {
    func testGroupsGenericProviderMetricsByDisplayPurpose() {
        let metrics = [
            Metric(id: "latency_ms", label: "Latency", value: .latency(ms: 42)),
            Metric(id: "download_bps", label: "Download", value: .throughput(bitsPerSecond: 12_000_000)),
            Metric(id: "battery_percent", label: "Battery", value: .percent(81)),
            Metric(id: "online", label: "Online", value: .bool(true)),
            Metric(id: "state", label: "State", value: .text("connected"))
        ]

        let sections = ProviderMetricSection.sections(from: metrics)

        XCTAssertEqual(sections.map(\.title), ["Network", "Power", "State"])
        XCTAssertEqual(sections[0].metrics.map(\.id), ["latency_ms", "download_bps"])
        XCTAssertEqual(sections[1].metrics.map(\.id), ["battery_percent"])
        XCTAssertEqual(sections[2].metrics.map(\.id), ["online", "state"])
    }

    func testKeepsUnknownMetricValuesInOtherSection() {
        let metrics = [
            Metric(id: "custom", label: "Custom", value: .level(3))
        ]

        let sections = ProviderMetricSection.sections(from: metrics)

        XCTAssertEqual(sections, [
            ProviderMetricSection(title: "Other", metrics: metrics)
        ])
    }
}
