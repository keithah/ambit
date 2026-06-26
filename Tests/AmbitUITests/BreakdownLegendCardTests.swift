import XCTest
@testable import AmbitUI
import AmbitCore

final class BreakdownLegendCardTests: XCTestCase {
    func testRowsBuildFromEntityReadoutsInSpecOrder() {
        let app = EntityID(rawValue: "system@local/overview.memory_app")
        let wired = EntityID(rawValue: "system@local/overview.memory_wired")
        let descriptors: [EntityID: EntityDescriptor] = [
            app: EntityDescriptor(id: app, instanceID: "system@local/overview", name: "App", kind: .sensor,
                                  deviceClass: .dataSize, capability: "system.memory"),
            wired: EntityDescriptor(id: wired, instanceID: "system@local/overview", name: "Wired", kind: .sensor,
                                    deviceClass: .dataSize, capability: "system.memory")
        ]
        let states: [EntityID: EntityState] = [
            app: EntityState(id: app, value: .number(6_000_000_000), availability: .online),
            wired: EntityState(id: wired, value: .number(2_000_000_000), availability: .online)
        ]

        let rows = BreakdownLegendCard.Model(
            entityIDs: [wired, app],
            data: SurfaceData(descriptors: descriptors, states: states)
        ).rows

        XCTAssertEqual(rows.map(\.id), [wired.rawValue, app.rawValue])
        XCTAssertEqual(rows.map(\.label), ["Wired", "App"])
        XCTAssertEqual(rows.map(\.value), ["2.0 GB", "6.0 GB"])
        XCTAssertEqual(rows.map(\.tone), [.good, .good])
    }
}
