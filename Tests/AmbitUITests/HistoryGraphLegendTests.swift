import XCTest
@testable import AmbitUI
import AmbitCore

final class HistoryGraphLegendTests: XCTestCase {
    func testGraphLinesMarkPrimaryWithoutChangingEntityOrderOrColors() {
        let now = Date(timeIntervalSince1970: 0)
        let first = EntityID(rawValue: "ping/a.latency")
        let second = EntityID(rawValue: "ping/b.latency")
        let data = SurfaceData(
            descriptors: [
                first: EntityDescriptor(id: first, instanceID: "ping/a/probe", name: "A", kind: .sensor, deviceClass: .latency),
                second: EntityDescriptor(id: second, instanceID: "ping/b/probe", name: "B", kind: .sensor, deviceClass: .latency)
            ],
            states: [:],
            series: [
                first: [Sample(timestamp: now, value: 10), Sample(timestamp: now.addingTimeInterval(1), value: 11)],
                second: [Sample(timestamp: now, value: 20), Sample(timestamp: now.addingTimeInterval(1), value: 21)]
            ],
            primaryEntityID: second
        )

        let lines = data.graphLines([first, second])

        XCTAssertEqual(lines.map(\.entityID), [first, second])
        XCTAssertEqual(lines.map(\.id), ["A", "B"])
        XCTAssertEqual(lines.map(\.isPrimary), [false, true])
        XCTAssertEqual(lines[0].color, Theme.lineColor(0))
        XCTAssertEqual(lines[1].color, Theme.lineColor(1))
        XCTAssertGreaterThan(lines[1].strokeWidth, lines[0].strokeWidth)
        XCTAssertGreaterThan(lines[1].opacity, lines[0].opacity)
    }

    func testGraphLinesFallBackToFirstEntityWhenPrimaryIsNil() {
        let first = EntityID(rawValue: "ping/a.latency")
        let second = EntityID(rawValue: "ping/b.latency")
        let data = SurfaceData(
            descriptors: [
                first: EntityDescriptor(id: first, instanceID: "ping/a/probe", name: "A", kind: .sensor, deviceClass: .latency),
                second: EntityDescriptor(id: second, instanceID: "ping/b/probe", name: "B", kind: .sensor, deviceClass: .latency)
            ],
            states: [:],
            series: [:],
            primaryEntityID: nil
        )

        XCTAssertEqual(data.graphLines([first, second]).map(\.isPrimary), [true, false])
    }

    @MainActor
    func testLegendEntriesOmitNoSampleLinesAndCapAtFour() {
        let now = Date(timeIntervalSince1970: 0)
        let lines = [
            GraphLine(id: "A", entityID: "a", color: Theme.lineColor(0), samples: [Sample(timestamp: now, value: 1)], isPrimary: false),
            GraphLine(id: "B", entityID: "b", color: Theme.lineColor(1), samples: [], isPrimary: false),
            GraphLine(id: "C", entityID: "c", color: Theme.lineColor(2), samples: [Sample(timestamp: now, value: 3)], isPrimary: true),
            GraphLine(id: "D", entityID: "d", color: Theme.lineColor(3), samples: [Sample(timestamp: now, value: 4)], isPrimary: false),
            GraphLine(id: "E", entityID: "e", color: Theme.lineColor(4), samples: [Sample(timestamp: now, value: 5)], isPrimary: false),
            GraphLine(id: "F", entityID: "f", color: Theme.lineColor(5), samples: [Sample(timestamp: now, value: 6)], isPrimary: false)
        ]
        let card = HistoryGraphCard(title: "Latency", lines: lines, showLegend: true)

        XCTAssertEqual(card.visibleLegendLines.map(\.id), ["A", "C", "D", "E"])
        XCTAssertEqual(card.visibleLegendLines.map(\.isPrimary), [false, true, false, false])
    }
}
