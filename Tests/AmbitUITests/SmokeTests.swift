import XCTest
@testable import AmbitUI

final class SmokeTests: XCTestCase {
    func testTargetBuildsAndExposesVersion() {
        XCTAssertEqual(AmbitUI.version, "p1")
    }
}
