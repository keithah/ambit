import XCTest
import CoreGraphics
@testable import AmbitUI
import AmbitCore

final class GraphGeometryTests: XCTestCase {
    func testNiceMaxRoundsUpToCleanCeiling() {
        XCTAssertEqual(GraphGeometry.niceMax([42, 120]), 150)
        XCTAssertEqual(GraphGeometry.niceMax([600]), 750)
        XCTAssertEqual(GraphGeometry.niceMax([]), 100)
        XCTAssertEqual(GraphGeometry.niceMax([0]), 100)
    }

    func testPointsMapValuesIntoBox() {
        let now = Date(timeIntervalSince1970: 0)
        let samples = [
            Sample(timestamp: now, value: 0),
            Sample(timestamp: now, value: 50),
            Sample(timestamp: now, value: 100)
        ]
        let pts = GraphGeometry.points(samples: samples, in: CGSize(width: 100, height: 100), axisMax: 100)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(pts[0].y, 100, accuracy: 0.001)   // value 0 → bottom
        XCTAssertEqual(pts[2].x, 100, accuracy: 0.001)
        XCTAssertEqual(pts[2].y, 0, accuracy: 0.001)     // value == axisMax → top
        XCTAssertEqual(pts[1].y, 50, accuracy: 0.001)
    }

    func testSeriesBreaksLineAtNilFailureAndReportsFailureX() {
        let now = Date(timeIntervalSince1970: 0)
        let samples = [
            Sample(timestamp: now, value: 0),
            Sample(timestamp: now, value: 50),
            Sample(timestamp: now, value: nil, ok: false),
            Sample(timestamp: now, value: 100),
            Sample(timestamp: now, value: 25)
        ]

        let geometry = GraphGeometry.series(samples: samples, in: CGSize(width: 100, height: 100), axisMax: 100)

        XCTAssertEqual(geometry.segments.count, 2)
        XCTAssertEqual(geometry.segments[0].map(\.x), [0, 25])
        XCTAssertEqual(geometry.segments[1].map(\.x), [75, 100])
        XCTAssertEqual(geometry.failureXPositions, [50])
        XCTAssertEqual(geometry.segments[0][0].y, 100, accuracy: 0.001)
        XCTAssertEqual(geometry.segments[0][1].y, 50, accuracy: 0.001)
        XCTAssertEqual(geometry.segments[1][0].y, 0, accuracy: 0.001)
    }

    func testSeriesTreatsNonOKValuedSampleAsFailureNotAPlottedPoint() {
        let now = Date(timeIntervalSince1970: 0)
        let samples = [
            Sample(timestamp: now, value: 10, ok: true),
            Sample(timestamp: now, value: 99, ok: false),
            Sample(timestamp: now, value: 20, ok: true)
        ]

        let geometry = GraphGeometry.series(samples: samples, in: CGSize(width: 20, height: 20), axisMax: 100)

        XCTAssertEqual(geometry.segments.count, 2)
        XCTAssertEqual(geometry.segments[0].count, 1)
        XCTAssertEqual(geometry.segments[1].count, 1)
        XCTAssertEqual(geometry.failureXPositions, [10])
        XCTAssertFalse(geometry.segments.flatMap { $0 }.contains { abs($0.y - 0.2) < 0.001 })
    }

    func testSeriesUsesPlotVerticalPaddingForValuesAndFailures() {
        let now = Date(timeIntervalSince1970: 0)
        let samples = [
            Sample(timestamp: now, value: 100),
            Sample(timestamp: now, value: nil, ok: false),
            Sample(timestamp: now, value: 0)
        ]

        let geometry = GraphGeometry.series(
            samples: samples,
            in: CGSize(width: 100, height: 100),
            axisMax: 100,
            plotVerticalPadding: 6
        )

        XCTAssertEqual(geometry.segments[0][0].y, 6, accuracy: 0.001)
        XCTAssertEqual(geometry.segments[1][0].y, 94, accuracy: 0.001)
        XCTAssertEqual(geometry.failureXPositions, [50])
    }

    func testNiceMaxScalesToThroughputMagnitude() {
        // 12 Mbps worth of bits/sec must not fall through to a latency-shaped ceiling.
        XCTAssertEqual(GraphGeometry.niceMax([12_000_000]), 15_000_000)
        XCTAssertEqual(GraphGeometry.niceMax([3]), 3)
        XCTAssertEqual(GraphGeometry.niceMax([45]), 50)
    }
}
