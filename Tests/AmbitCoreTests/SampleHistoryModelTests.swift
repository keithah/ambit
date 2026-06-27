import XCTest
@testable import AmbitCore

final class SampleHistoryModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testRowsMapSuccessAndFailureSamplesWithMetadata() {
        let descriptor = latencyDescriptor()
        let samples = [
            Sample(timestamp: t0, value: 12.4, ok: true),
            Sample(timestamp: t0.addingTimeInterval(1), value: nil, ok: false, metadata: "Timed out"),
            Sample(timestamp: t0.addingTimeInterval(2), value: 50, ok: false, metadata: "Rejected")
        ]

        let rows = SampleHistoryModel.rows(samples: samples, descriptor: descriptor, limit: 8)

        XCTAssertEqual(rows.map(\.timestamp), [t0.addingTimeInterval(2), t0.addingTimeInterval(1), t0])
        XCTAssertEqual(rows.map(\.result), ["Rejected", "Timed out", "12ms"])
        XCTAssertEqual(rows.map(\.isFailure), [true, true, false])
        XCTAssertEqual(rows.map(\.status), ["Failed", "Failed", "OK"])
    }

    func testFailureWithoutMetadataUsesGenericFailedLabel() {
        let rows = SampleHistoryModel.rows(
            samples: [Sample(timestamp: t0, value: nil, ok: false)],
            descriptor: latencyDescriptor(),
            limit: 8
        )

        XCTAssertEqual(rows[0].result, "Failed")
        XCTAssertTrue(rows[0].isFailure)
        XCTAssertEqual(rows[0].status, "Failed")
    }

    func testRowsAreMostRecentFirstAndCapped() {
        let samples = (0..<10).map { offset in
            Sample(timestamp: t0.addingTimeInterval(Double(offset)), value: Double(offset), ok: true)
        }

        let rows = SampleHistoryModel.rows(samples: samples, descriptor: latencyDescriptor(), limit: 3)

        XCTAssertEqual(rows.map(\.timestamp), [
            t0.addingTimeInterval(9),
            t0.addingTimeInterval(8),
            t0.addingTimeInterval(7)
        ])
        XCTAssertEqual(rows.map(\.result), ["9ms", "8ms", "7ms"])
    }

    func testEmptyStateMessageMentionsSelectedRange() {
        XCTAssertEqual(SampleHistoryModel.emptyMessage(rangeLabel: "5m"), "No samples in the last 5m.")
        XCTAssertEqual(SampleHistoryModel.emptyMessage(rangeLabel: nil), "No samples yet.")
    }

    private func latencyDescriptor() -> EntityDescriptor {
        EntityDescriptor(
            id: "ping@1.1.1.1/probe.latency_ms",
            instanceID: "ping@1.1.1.1/probe",
            name: "Latency",
            kind: .sensor,
            deviceClass: .latency,
            unit: "ms",
            stateClass: .measurement
        )
    }
}
