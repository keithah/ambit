import XCTest
@testable import AmbitUI
import AmbitCore

final class SegmentedRingCardTests: XCTestCase {
    func testSegmentsBuildFromEntityStatesAndIgnoreMissingValues() {
        let app = EntityID(rawValue: "system@local/overview.memory_app")
        let wired = EntityID(rawValue: "system@local/overview.memory_wired")
        let missing = EntityID(rawValue: "system@local/overview.memory_missing")
        let descriptors: [EntityID: EntityDescriptor] = [
            app: EntityDescriptor(id: app, instanceID: "system@local/overview", name: "App", kind: .sensor,
                                  deviceClass: .dataSize, capability: "system.memory", unit: "GB"),
            wired: EntityDescriptor(id: wired, instanceID: "system@local/overview", name: "Wired", kind: .sensor,
                                    deviceClass: .dataSize, capability: "system.memory", unit: "GB"),
            missing: EntityDescriptor(id: missing, instanceID: "system@local/overview", name: "Missing", kind: .sensor,
                                      deviceClass: .dataSize, capability: "system.memory", unit: "GB")
        ]
        let states: [EntityID: EntityState] = [
            app: EntityState(id: app, value: .number(6_000_000_000), availability: .online),
            wired: EntityState(id: wired, value: .number(2_000_000_000), availability: .online),
            missing: EntityState(id: missing, value: nil, availability: .online)
        ]

        let segments = SegmentedRingCard.Model(
            entityIDs: [app, wired, missing],
            data: SurfaceData(descriptors: descriptors, states: states)
        ).segments

        XCTAssertEqual(segments.map(\.id), [app.rawValue, wired.rawValue])
        XCTAssertEqual(segments.map(\.label), ["App", "Wired"])
        XCTAssertEqual(segments.map(\.value), [6_000_000_000, 2_000_000_000])
        XCTAssertEqual(segments.map(\.fraction), [0.75, 0.25])
        XCTAssertEqual(segments.map(\.readout), ["6.0 GB", "2.0 GB"])
    }
}
