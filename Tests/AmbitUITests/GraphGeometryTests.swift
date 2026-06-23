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

    func testMissingValueTreatedAsZero() {
        let now = Date(timeIntervalSince1970: 0)
        let pts = GraphGeometry.points(samples: [Sample(timestamp: now, value: nil, ok: false), Sample(timestamp: now, value: 100)],
                                       in: CGSize(width: 10, height: 10), axisMax: 100)
        XCTAssertEqual(pts[0].y, 10, accuracy: 0.001)  // nil → 0 → bottom
    }
}
