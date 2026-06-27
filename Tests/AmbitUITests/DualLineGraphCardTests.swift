import XCTest
@testable import AmbitUI
import AmbitCore

@MainActor
final class DualLineGraphCardTests: XCTestCase {
    func testEmptyDualLineGraphHasNoDrawableSeries() {
        let card = DualLineGraphCard(title: "CPU", lines: [
            GraphLine(id: "User", color: Theme.lineColor(0), samples: []),
            GraphLine(id: "System", color: Theme.lineColor(1), samples: [])
        ])

        XCTAssertFalse(card.hasDrawableSeries)
    }

    func testDualLineGraphHasDrawableSeriesWhenAnyLineHasTwoMeasuredSamples() {
        let now = Date(timeIntervalSince1970: 0)
        let card = DualLineGraphCard(title: "CPU", lines: [
            GraphLine(id: "User", color: Theme.lineColor(0), samples: [
                Sample(timestamp: now, value: 10),
                Sample(timestamp: now.addingTimeInterval(1), value: 20)
            ]),
            GraphLine(id: "System", color: Theme.lineColor(1), samples: [])
        ])

        XCTAssertTrue(card.hasDrawableSeries)
    }
}
