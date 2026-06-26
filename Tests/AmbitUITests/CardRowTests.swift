import XCTest
@testable import AmbitUI
import AmbitCore

final class CardRowTests: XCTestCase {
    func testCardRowSpecPreservesChildCardsAndHasNoEntities() {
        let childA = CardSpec(id: "card.a", kind: .gauge, entities: ["i/p.a"])
        let childB = CardSpec(id: "card.b", kind: .progress, entities: ["i/p.b"])

        let row = CardSpec(id: "row:CPU:0", kind: .cardRow, children: [childA, childB])

        XCTAssertEqual(row.entities, [])
        XCTAssertEqual(row.children.map(\.id), ["card.a", "card.b"])
        XCTAssertEqual(row.children.map(\.kind), [.gauge, .progress])
    }
}
