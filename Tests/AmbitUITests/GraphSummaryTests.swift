import XCTest
@testable import AmbitUI
import AmbitCore

final class GraphSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    func testSummaryProducesAllSixStats() {
        // 4 probes, one failed → TX 4, RX 3, Loss 25%; valued [10,20,30] → min/avg/max.
        let samples = [
            Sample(timestamp: now, value: 10),
            Sample(timestamp: now, value: 20),
            Sample(timestamp: now, value: 30),
            Sample(timestamp: now, value: nil, ok: false)
        ]
        let items = GraphSummary.summary(samples: samples, deviceClass: .latency, unit: "ms")
        XCTAssertEqual(items, [
            GraphSummaryItem(label: "TX", value: "4"),
            GraphSummaryItem(label: "RX", value: "3"),
            GraphSummaryItem(label: "Loss", value: "25%"),
            GraphSummaryItem(label: "Min", value: "10ms"),
            GraphSummaryItem(label: "Avg", value: "20ms"),
            GraphSummaryItem(label: "Max", value: "30ms")
        ])
    }

    func testThroughputSummaryUsesUnitFormatter() {
        let items = GraphSummary.summary(samples: [Sample(timestamp: now, value: 12_000_000)], deviceClass: .throughput, unit: "bps")
        XCTAssertEqual(items.first { $0.label == "Min" }?.value, "12.0 Mbps")
    }

    func testGenericMeasurementSummaryOmitsPingProbeVocabulary() {
        let samples = [
            Sample(timestamp: now, value: 1.2),
            Sample(timestamp: now.addingTimeInterval(1), value: 1.8),
            Sample(timestamp: now.addingTimeInterval(2), value: 1.5)
        ]

        let items = GraphSummary.summary(samples: samples, deviceClass: .count, unit: nil)

        XCTAssertEqual(items, [
            GraphSummaryItem(label: "Min", value: "1"),
            GraphSummaryItem(label: "Avg", value: "2"),
            GraphSummaryItem(label: "Max", value: "2"),
            GraphSummaryItem(label: "Current", value: "2")
        ])
        XCTAssertFalse(items.map(\.label).contains("TX"))
        XCTAssertFalse(items.map(\.label).contains("RX"))
        XCTAssertFalse(items.map(\.label).contains("Loss"))
    }

    func testNoValuedSamplesKeepsCountsAndDashesValueStats() {
        let items = GraphSummary.summary(samples: [Sample(timestamp: now, value: nil, ok: false)], deviceClass: .latency, unit: "ms")
        XCTAssertEqual(items.map(\.label), ["TX", "RX", "Loss", "Min", "Avg", "Max"])
        XCTAssertEqual(items.first { $0.label == "Loss" }?.value, "100%")
        XCTAssertEqual(items.first { $0.label == "Min" }?.value, "—")
    }

    func testEmptySeriesHasNoSummary() {
        XCTAssertTrue(GraphSummary.summary(samples: [], deviceClass: .latency, unit: "ms").isEmpty)
    }
}
