import XCTest
@testable import AmbitUI
import AmbitCore

final class GraphSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    func testLatencyMinAvgMaxFormatted() {
        let samples = [Sample(timestamp: now, value: 10), Sample(timestamp: now, value: 20), Sample(timestamp: now, value: 30)]
        let items = GraphSummary.minAvgMax(samples: samples, deviceClass: .latency, unit: "ms")
        XCTAssertEqual(items, [
            GraphSummaryItem(label: "Min", value: "10ms"),
            GraphSummaryItem(label: "Avg", value: "20ms"),
            GraphSummaryItem(label: "Max", value: "30ms")
        ])
    }

    func testThroughputUsesUnitFormatter() {
        let items = GraphSummary.minAvgMax(samples: [Sample(timestamp: now, value: 12_000_000)], deviceClass: .throughput, unit: "bps")
        XCTAssertEqual(items.first?.value, "12.0 Mbps")
    }

    func testNoValuedSamplesIsEmpty() {
        XCTAssertTrue(GraphSummary.minAvgMax(samples: [Sample(timestamp: now, value: nil, ok: false)], deviceClass: .latency, unit: "ms").isEmpty)
    }
}
