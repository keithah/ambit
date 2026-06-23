import XCTest
import SwiftUI
@testable import AmbitUI
import AmbitCore

final class ThemeTests: XCTestCase {
    func testEveryToneHasAColorMapping() {
        let mapped = [DisplayTone.neutral, .good, .warn, .bad].map { $0.color }
        XCTAssertEqual(mapped.count, 4)
    }
}
