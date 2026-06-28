import XCTest
@testable import AmbitCore

final class PresentationConfigTests: XCTestCase {
    func testEmptyConfigHasNoOverrides() {
        let c = PresentationConfig.empty
        XCTAssertTrue(c.entityOverrides.isEmpty)
        XCTAssertTrue(c.integrationOverrides.isEmpty)
        XCTAssertTrue(c.slotOverrides.isEmpty)
    }

    func testConfigRoundTripsThroughCodable() throws {
        var c = PresentationConfig.empty
        c.entityOverrides["ping/probe.latency"] = EntityPresentationOverride(
            visibility: .always, graphStyle: .sparkline, graphRange: .m1, enabled: true
        )
        c.slotOverrides[SlotID(rawValue: "slot.system")] = SlotPresentationOverride(
            shownItems: [SurfaceItemID(rawValue: "entity:system@local/overview.cpu_usage_percent")],
            hiddenItems: [SurfaceItemID(rawValue: "group:system.memory:dataSize:B:segments")],
            selectedInstanceID: IntegrationInstanceID(rawValue: "system@local"),
            primaryInstanceID: IntegrationInstanceID(rawValue: "system@local"),
            showsAllInstances: false
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: data)
        XCTAssertEqual(decoded, c)
    }

    func testSlotPresentationOverrideDecodesWithDefaults() throws {
        let json = #"{"slots":[]}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: json)

        XCTAssertTrue(decoded.slotOverrides.isEmpty)
    }

    func testSlotPresentationOverrideDecodesFocusDefaults() throws {
        let json = #"{"shownItems":[]}"#.data(using: .utf8)!

        let override = try JSONDecoder().decode(SlotPresentationOverride.self, from: json)

        XCTAssertNil(override.selectedInstanceID)
        XCTAssertNil(override.primaryInstanceID)
        XCTAssertFalse(override.showsAllInstances)
    }
}
