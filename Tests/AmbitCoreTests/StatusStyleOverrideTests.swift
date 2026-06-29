import XCTest
@testable import AmbitCore

final class StatusStyleOverrideTests: XCTestCase {
    func testStatusStylePaletteUsesOverrideForToneAndDefaultOtherwise() {
        let palette = StatusStylePalette(overrides: [
            .bad: StatusStyleOverride(colorHex: "#ff00aa")
        ])

        XCTAssertEqual(palette.colorHex(for: .bad), "#ff00aa")
        XCTAssertEqual(palette.colorHex(for: .good), StatusStylePalette.defaultColorHex(for: .good))
    }

    func testPresentationConfigDecodesAlertKindAndStatusStyleDefaults() throws {
        let config = try JSONDecoder().decode(PresentationConfig.self, from: Data("{}".utf8))

        XCTAssertTrue(config.alertKindOverrides.isEmpty)
        XCTAssertTrue(config.entityAlertKindOverrides.isEmpty)
        XCTAssertTrue(config.statusStyleOverrides.isEmpty)
    }

    func testAlertKindSettingsRowsRenderNonPingDeclarations() {
        let record = IntegrationInstanceRecord(
            id: IntegrationInstanceID(rawValue: "fixture@local"),
            integrationID: IntegrationID(rawValue: "fixture"),
            displayName: "Fixture",
            enabled: true
        )
        let declaration = AlertKindDeclaration(
            id: AlertKindID(rawValue: "fixture.wanDown"),
            titleTemplate: "WAN down",
            messageTemplate: "No response from WAN.",
            severity: .down,
            defaultEnabled: true,
            target: .entity(EntityID(rawValue: "fixture@local/wan.status")),
            trigger: .healthTransition(to: .down),
            cooldown: 60
        )
        var config = PresentationConfig.empty
        config.alertKindOverrides[declaration.id] = AlertKindOverride(enabled: false)

        let rows = AlertKindSettingsModel.rows(
            records: [record],
            declarationsByInstance: [record.id: [declaration]],
            config: config
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kindID, declaration.id)
        XCTAssertEqual(rows.first?.integrationName, "Fixture")
        XCTAssertEqual(rows.first?.enabled, false)
    }
}
