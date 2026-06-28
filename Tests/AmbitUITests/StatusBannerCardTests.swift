import XCTest
@testable import AmbitUI

final class StatusBannerCardTests: XCTestCase {
    func testCompactReasonModelCombinesTitleAndDetailOnOneLine() {
        let model = StatusBannerCard.Model(
            title: "Local network degraded",
            detail: "1/2 gateway host(s) unreachable.",
            tone: .warn,
            isCompactReason: true
        )

        XCTAssertEqual(model.primaryLine, "Local network degraded · 1/2 gateway host(s) unreachable.")
        XCTAssertNil(model.detailLine)
        XCTAssertEqual(model.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(model.verticalPadding, 7)
    }

    func testStandardModelKeepsTitleAndDetailSeparate() {
        let model = StatusBannerCard.Model(
            title: "Local network degraded",
            detail: "1/2 gateway host(s) unreachable.",
            tone: .warn,
            isCompactReason: false
        )

        XCTAssertEqual(model.primaryLine, "Local network degraded")
        XCTAssertEqual(model.detailLine, "1/2 gateway host(s) unreachable.")
        XCTAssertEqual(model.verticalPadding, 10)
    }
}
