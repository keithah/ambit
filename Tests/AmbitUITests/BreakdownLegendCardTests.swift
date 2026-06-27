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

    func testMemoryBreakdownRowsListAllComponentsInGB() {
        let app = EntityID(rawValue: "system@local/overview.memory_app_active_bytes")
        let wired = EntityID(rawValue: "system@local/overview.memory_wired_bytes")
        let compressed = EntityID(rawValue: "system@local/overview.memory_compressed_bytes")
        let free = EntityID(rawValue: "system@local/overview.memory_free_bytes")
        let descriptors: [EntityID: EntityDescriptor] = [
            app: EntityDescriptor(id: app, instanceID: "system@local/overview", name: "App/Active", kind: .sensor, deviceClass: .dataSize, capability: "system.memory", unit: "B"),
            wired: EntityDescriptor(id: wired, instanceID: "system@local/overview", name: "Wired", kind: .sensor, deviceClass: .dataSize, capability: "system.memory", unit: "B"),
            compressed: EntityDescriptor(id: compressed, instanceID: "system@local/overview", name: "Compressed", kind: .sensor, deviceClass: .dataSize, capability: "system.memory", unit: "B"),
            free: EntityDescriptor(id: free, instanceID: "system@local/overview", name: "Free", kind: .sensor, deviceClass: .dataSize, capability: "system.memory", unit: "B")
        ]
        let states: [EntityID: EntityState] = [
            app: EntityState(id: app, value: .number(4_000_000_000), availability: .online),
            wired: EntityState(id: wired, value: .number(2_000_000_000), availability: .online),
            compressed: EntityState(id: compressed, value: .number(1_000_000_000), availability: .online),
            free: EntityState(id: free, value: .number(3_000_000_000), availability: .online)
        ]

        let rows = BreakdownLegendCard.Model(
            entityIDs: [app, wired, compressed, free],
            data: SurfaceData(descriptors: descriptors, states: states)
        ).rows

        XCTAssertEqual(rows.map(\.label), ["App/Active", "Wired", "Compressed", "Free"])
        XCTAssertEqual(rows.map(\.value), ["4.0 GB", "2.0 GB", "1.0 GB", "3.0 GB"])
    }
}
