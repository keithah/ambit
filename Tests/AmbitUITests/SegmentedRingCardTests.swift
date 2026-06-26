import XCTest
@testable import AmbitUI
import AmbitCore

final class SegmentedRingCardTests: XCTestCase {
    func testSegmentsBuildFromSummedTotal() {
        let app = EntityID(rawValue: "system@local/overview.memory_app")
        let wired = EntityID(rawValue: "system@local/overview.memory_wired")
        let descriptors: [EntityID: EntityDescriptor] = [
            app: EntityDescriptor(id: app, instanceID: "system@local/overview", name: "App", kind: .sensor,
                                  deviceClass: .dataSize, capability: "system.memory", unit: "GB",
                                  compositionRole: .segment),
            wired: EntityDescriptor(id: wired, instanceID: "system@local/overview", name: "Wired", kind: .sensor,
                                    deviceClass: .dataSize, capability: "system.memory", unit: "GB",
                                    compositionRole: .segment)
        ]
        let states: [EntityID: EntityState] = [
            app: EntityState(id: app, value: .number(6_000_000_000), availability: .online),
            wired: EntityState(id: wired, value: .number(2_000_000_000), availability: .online)
        ]

        let model = SegmentedRingCard.Model(
            entityIDs: [app, wired],
            data: SurfaceData(descriptors: descriptors, states: states)
        )

        let segments = model.segments
        XCTAssertEqual(segments.map(\.id), [app.rawValue, wired.rawValue])
        XCTAssertEqual(segments.map(\.label), ["App", "Wired"])
        XCTAssertEqual(segments.map(\.value), [6_000_000_000, 2_000_000_000])
        XCTAssertEqual(segments.map(\.fraction), [0.75, 0.25])
        XCTAssertEqual(segments.map(\.readout), ["6.0 GB", "2.0 GB"])
        XCTAssertEqual(model.total, 8_000_000_000)
        XCTAssertEqual(model.centerReadout, "6.0 GB")
    }

    func testExplicitTotalAndRemainderProduceUnfilledTrackAndCenterReadout() {
        let used = EntityID(rawValue: "system@local/overview.memory_used")
        let free = EntityID(rawValue: "system@local/overview.memory_free")
        let total = EntityID(rawValue: "system@local/overview.memory_total")
        let descriptors: [EntityID: EntityDescriptor] = [
            used: EntityDescriptor(id: used, instanceID: "system@local/overview", name: "Used", kind: .sensor,
                                   deviceClass: .dataSize, capability: "system.memory", unit: "GB",
                                   graphStyle: .progress, isPrimary: true, compositionRole: .segment),
            free: EntityDescriptor(id: free, instanceID: "system@local/overview", name: "Free", kind: .sensor,
                                   deviceClass: .dataSize, capability: "system.memory", unit: "GB",
                                   graphStyle: .progress, compositionRole: .remainder),
            total: EntityDescriptor(id: total, instanceID: "system@local/overview", name: "Total", kind: .sensor,
                                    deviceClass: .dataSize, capability: "system.memory", unit: "GB",
                                    graphStyle: .progress, compositionRole: .total)
        ]
        let states: [EntityID: EntityState] = [
            used: EntityState(id: used, value: .number(6_000_000_000), availability: .online),
            free: EntityState(id: free, value: .number(4_000_000_000), availability: .online),
            total: EntityState(id: total, value: .number(10_000_000_000), availability: .online)
        ]

        let model = SegmentedRingCard.Model(
            entityIDs: [used, free, total],
            data: SurfaceData(descriptors: descriptors, states: states)
        )

        XCTAssertEqual(model.total, 10_000_000_000)
        XCTAssertEqual(model.centerReadout, "6.0 GB")
        XCTAssertEqual(model.segments.map(\.id), [used.rawValue])
        XCTAssertEqual(model.remainder?.id, free.rawValue)
        XCTAssertEqual(model.remainder?.fraction, 0.4)
        XCTAssertEqual(model.segments.first?.fraction, 0.6)
    }

    func testIncompleteWholeDoesNotProduceMisleadingSegments() {
        let used = EntityID(rawValue: "system@local/overview.memory_used")
        let free = EntityID(rawValue: "system@local/overview.memory_free")
        let descriptors: [EntityID: EntityDescriptor] = [
            used: EntityDescriptor(id: used, instanceID: "system@local/overview", name: "Used", kind: .sensor,
                                   deviceClass: .dataSize, capability: "system.memory",
                                   compositionRole: .segment),
            free: EntityDescriptor(id: free, instanceID: "system@local/overview", name: "Free", kind: .sensor,
                                   deviceClass: .dataSize, capability: "system.memory",
                                   compositionRole: .remainder)
        ]
        let states: [EntityID: EntityState] = [
            used: EntityState(id: used, value: .number(6_000_000_000), availability: .online),
            free: EntityState(id: free, value: nil, availability: .unavailable)
        ]

        let model = SegmentedRingCard.Model(
            entityIDs: [used, free],
            data: SurfaceData(descriptors: descriptors, states: states)
        )

        XCTAssertTrue(model.isIncomplete)
        XCTAssertTrue(model.segments.isEmpty)
    }
}
