import XCTest
@testable import AmbitUI
import AmbitCore

final class StatTableCardTests: XCTestCase {
    func testTableValueBuildsGenericRenderableModel() {
        let table = TableValue(
            columns: [
                TableColumn(id: "process", title: "Process", alignment: .leading, valueStyle: .text),
                TableColumn(id: "cpu", title: "CPU", alignment: .trailing, valueStyle: .number),
                TableColumn(id: "state", title: "State", alignment: .center, valueStyle: .badge)
            ],
            rows: [
                TableRow(id: "123:WindowServer", cells: [
                    "process": .text("WindowServer"),
                    "cpu": .number(18.4, unit: "%"),
                    "state": .badge("High", .elevated)
                ])
            ]
        )

        let model = StatTableCard.Model(table: table)

        XCTAssertEqual(model.columns.map(\.title), ["Process", "CPU", "State"])
        XCTAssertEqual(model.columns.map(\.alignment), [.leading, .trailing, .center])
        XCTAssertEqual(model.rows.map(\.id), ["123:WindowServer"])
        XCTAssertEqual(model.rows[0].cells.map(\.text), ["WindowServer", "18.4%", "High"])
        XCTAssertEqual(model.rows[0].cells.map(\.tone), [.neutral, .neutral, .warn])
    }

    func testLegacyLabelValueRowsRemainAvailable() {
        let rows = [StatTableCard.Row(id: "tx", label: "TX", value: "146")]

        XCTAssertEqual(rows[0].id, "tx")
        XCTAssertEqual(rows[0].label, "TX")
        XCTAssertEqual(rows[0].value, "146")
    }
}
