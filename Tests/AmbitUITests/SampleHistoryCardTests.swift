import XCTest
@testable import AmbitUI
import AmbitCore

final class SampleHistoryCardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testModelBuildsSingleLineRowsAndFailureTone() {
        let descriptor = EntityDescriptor(
            id: "ping@1.1.1.1/probe.latency_ms",
            instanceID: "ping@1.1.1.1/probe",
            name: "Latency",
            kind: .sensor,
            deviceClass: .latency,
            unit: "ms",
            stateClass: .measurement
        )
        let rows = SampleHistoryModel.rows(samples: [
            Sample(timestamp: t0, value: 8, ok: true),
            Sample(timestamp: t0.addingTimeInterval(1), value: nil, ok: false, metadata: "Host unreachable")
        ], descriptor: descriptor, limit: SampleHistoryCard.Model.defaultRowLimit)

        let model = SampleHistoryCard.Model(rows: rows)
        let failureTime = SampleHistoryCard.Model.timeText(t0.addingTimeInterval(1))
        let successTime = SampleHistoryCard.Model.timeText(t0)

        XCTAssertEqual(model.columns.map(\.title), ["Time", "Result", "Status"])
        XCTAssertEqual(model.rows.map(\.cells).map { $0.map(\.text) }, [
            [failureTime, "Host unreachable", "Failed"],
            [successTime, "8ms", "OK"]
        ])
        XCTAssertEqual(model.rows[0].cells[1].tone, .bad)
        XCTAssertTrue(model.rows.flatMap(\.cells).allSatisfy(\.isSingleLine))
    }

    func testDefaultRowLimitIsEight() {
        XCTAssertEqual(SampleHistoryCard.Model.defaultRowLimit, 8)
    }

    func testCompactTableMetricsFitEightRowsLikePingscope() {
        XCTAssertEqual(SampleHistoryCard.Model.rowVerticalPadding, 4)
        XCTAssertEqual(SampleHistoryCard.Model.headerVerticalPadding, 5)
        XCTAssertEqual(SampleHistoryCard.Model.rowFontSize, 11.5)
    }

    func testEmptyModelCarriesEmptyMessage() {
        let model = SampleHistoryCard.Model(rows: [], emptyMessage: "No samples in the last 5m.")

        XCTAssertEqual(model.emptyMessage, "No samples in the last 5m.")
        XCTAssertTrue(model.rows.isEmpty)
    }
}
