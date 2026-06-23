import XCTest
@testable import AmbitCore

final class CardSpecTests: XCTestCase {
    func testCardKindCoversTheVocabulary() {
        let kinds: Set<CardKind> = [
            .statusRow, .gauge, .historyGraph, .dualLineGraph, .progress,
            .statTable, .control, .instanceSelector, .section, .statusBanner
        ]
        XCTAssertEqual(kinds.count, 10)
    }

    func testSectionCardNestsChildren() {
        let child = CardSpec(id: "c1", kind: .statusRow, entities: ["glinet/router.health"])
        let section = CardSpec(id: "s1", kind: .section, title: "Network", children: [child])
        XCTAssertEqual(section.children.first, child)
        XCTAssertEqual(section.kind, .section)
    }

    func testSurfacePlanEquatable() {
        let a = SurfacePlan(cards: [CardSpec(id: "x", kind: .gauge, entities: ["e"])])
        let b = SurfacePlan(cards: [CardSpec(id: "x", kind: .gauge, entities: ["e"])])
        XCTAssertEqual(a, b)
    }
}
