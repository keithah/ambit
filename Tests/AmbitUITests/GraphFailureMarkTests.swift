import XCTest
import CoreGraphics
@testable import AmbitUI

final class GraphFailureMarkTests: XCTestCase {
    func testSingleLineFailureStyleMatchesPingscopeConstants() {
        let style = GraphFailureMarkStyle.style(isMultiLine: false, isPrimaryLine: true)

        XCTAssertEqual(style?.redOpacity, 0.72)
        XCTAssertEqual(style?.lineWidth, 1.5)
    }

    func testMultiLineFailureStyleOnlyDrawsForPrimaryLine() {
        let primary = GraphFailureMarkStyle.style(isMultiLine: true, isPrimaryLine: true)
        let secondary = GraphFailureMarkStyle.style(isMultiLine: true, isPrimaryLine: false)

        XCTAssertEqual(primary?.redOpacity, 0.55)
        XCTAssertEqual(primary?.lineWidth, 1.2)
        XCTAssertNil(secondary)
    }

    func testFailureMarkRunsFromTwentyPercentOfPlotHeightToBaseline() {
        let endpoints = GraphGeometry.failureMarkEndpoints(
            x: 25,
            in: CGSize(width: 100, height: 100),
            plotVerticalPadding: 6
        )

        XCTAssertEqual(endpoints.start.x, 25, accuracy: 0.001)
        XCTAssertEqual(endpoints.end.x, 25, accuracy: 0.001)
        XCTAssertEqual(endpoints.start.y, 23.6, accuracy: 0.001)
        XCTAssertEqual(endpoints.end.y, 94, accuracy: 0.001)
    }
}
