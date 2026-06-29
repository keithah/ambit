import XCTest
@testable import AmbitCore

final class PresentationConfigTests: XCTestCase {
    func testEmptyConfigHasNoOverrides() {
        let c = PresentationConfig.empty
        XCTAssertTrue(c.entityOverrides.isEmpty)
        XCTAssertTrue(c.integrationOverrides.isEmpty)
        XCTAssertTrue(c.slotOverrides.isEmpty)
        XCTAssertEqual(c.overlay, OverlayPresentationConfig())
    }

    func testConfigRoundTripsThroughCodable() throws {
        var c = PresentationConfig.empty
        c.entityOverrides["ping/probe.latency"] = EntityPresentationOverride(
            visibility: .always, graphStyle: .sparkline, graphRange: .m1, enabled: true
        )
        c.slotOverrides[SlotID(rawValue: "slot.system")] = SlotPresentationOverride(
            shownItems: [SurfaceItemID(rawValue: "entity:system@local/overview.cpu_usage_percent")],
            hiddenItems: [SurfaceItemID(rawValue: "group:system.memory:dataSize:B:segments")],
            graphRange: .h1,
            selectedInstanceID: IntegrationInstanceID(rawValue: "system@local"),
            primaryInstanceID: IntegrationInstanceID(rawValue: "system@local"),
            showsAllInstances: false
        )
        c.overlay = OverlayPresentationConfig(
            selectedSlotID: "system@local",
            isVisible: true,
            alwaysOnTop: false,
            compactMode: true,
            opacity: 0.72,
            frame: OverlayFrame(x: 10, y: 20, width: 300, height: 140)
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

    func testOverlayConfigDecodesWithDefaults() throws {
        let json = #"{"slots":[]}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PresentationConfig.self, from: json)

        XCTAssertEqual(decoded.overlay, OverlayPresentationConfig())
        XCTAssertFalse(decoded.overlay.isVisible)
        XCTAssertTrue(decoded.overlay.alwaysOnTop)
        XCTAssertFalse(decoded.overlay.compactMode)
        XCTAssertEqual(decoded.overlay.opacity, 1)
        XCTAssertNil(decoded.overlay.frame)
    }

    func testOverlayConfigClampsOpacityAndFrameSize() {
        let config = OverlayPresentationConfig(
            opacity: 2,
            frame: OverlayFrame(x: 0, y: 0, width: 20, height: 10)
        )

        XCTAssertEqual(config.opacity, 1)
        XCTAssertEqual(config.frame?.width, 180)
        XCTAssertEqual(config.frame?.height, 64)
    }
}
