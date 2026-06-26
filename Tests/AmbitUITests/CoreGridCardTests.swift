import XCTest
@testable import AmbitUI
import AmbitCore

final class CoreGridCardTests: XCTestCase {
    func testCellsUsePercentBoundsAndUnavailableState() {
        let core1 = EntityID(rawValue: "system@local/overview.cpu_core_1")
        let core2 = EntityID(rawValue: "system@local/overview.cpu_core_2")
        let descriptors: [EntityID: EntityDescriptor] = [
            core1: EntityDescriptor(id: core1, instanceID: "system@local/overview", name: "Core 1", kind: .sensor,
                                    deviceClass: .percent, capability: "system.cpu", unit: "%",
                                    compositionRole: .channel),
            core2: EntityDescriptor(id: core2, instanceID: "system@local/overview", name: "Core 2", kind: .sensor,
                                    deviceClass: .percent, capability: "system.cpu", unit: "%",
                                    compositionRole: .channel)
        ]
        let states: [EntityID: EntityState] = [
            core1: EntityState(id: core1, value: .number(75), availability: .online),
            core2: EntityState(id: core2, value: nil, availability: .unavailable)
        ]

        let model = CoreGridCard.Model(
            entityIDs: [core1, core2],
            data: SurfaceData(descriptors: descriptors, states: states)
        )

        XCTAssertEqual(model.cells.map(\.id), [core1.rawValue, core2.rawValue])
        XCTAssertEqual(model.cells.map(\.label), ["Core 1", "Core 2"])
        XCTAssertEqual(model.cells.map(\.readout), ["75%", "Down"])
        XCTAssertEqual(model.cells.map(\.fraction), [0.75, nil])
        XCTAssertEqual(model.cells.map(\.isUnavailable), [false, true])
    }
}
