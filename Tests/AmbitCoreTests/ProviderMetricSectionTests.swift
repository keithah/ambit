import XCTest
@testable import AmbitCore

final class ProviderMetricSectionTests: XCTestCase {
    func testGroupsGenericProviderMetricsByDisplayPurpose() {
        let metrics = [
            Metric(id: "latency_ms", label: "Latency", value: .latency(ms: 42)),
            Metric(id: "download_bps", label: "Download", value: .throughput(bitsPerSecond: 12_000_000)),
            Metric(id: "battery_percent", label: "Battery", value: .percent(81), deviceClass: .battery),
            Metric(id: "online", label: "Online", value: .bool(true)),
            Metric(id: "state", label: "State", value: .text("connected"))
        ]

        let sections = ProviderMetricSection.sections(from: metrics)

        XCTAssertEqual(sections.map(\.title), ["Network", "Power", "State"])
        XCTAssertEqual(sections[0].metrics.map(\.id), ["latency_ms", "download_bps"])
        XCTAssertEqual(sections[1].metrics.map(\.id), ["battery_percent"])
        XCTAssertEqual(sections[2].metrics.map(\.id), ["online", "state"])
    }

    func testDeviceClassDrivesGroupingOverValueShape() {
        // A power-classed metric whose value happens to be a percentage still groups under
        // Power — proving classification wins and there is no id-substring heuristic.
        let metrics = [
            Metric(id: "soc", label: "State of Charge", value: .percent(64), deviceClass: .battery),
            Metric(id: "load", label: "Load", value: .level(120), deviceClass: .power),
            Metric(id: "battery_note", label: "Note", value: .text("ok"))
        ]

        let sections = ProviderMetricSection.sections(from: metrics)

        XCTAssertEqual(sections.map(\.title), ["Power", "State"])
        XCTAssertEqual(sections[0].metrics.map(\.id), ["soc", "load"])
        // "battery_note" no longer lands in Power despite its id — heuristic is gone.
        XCTAssertEqual(sections[1].metrics.map(\.id), ["battery_note"])
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
