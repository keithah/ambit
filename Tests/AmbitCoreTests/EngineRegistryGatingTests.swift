import XCTest
@testable import AmbitCore

final class EngineRegistryGatingTests: XCTestCase {
    func testDisabledBuiltInIntegrationsAreNeverRegistered() async {
        // Built-in instance records exist but every built-in integration type is disabled —
        // the M0 "only pingscope active" state. None should be assembled (so none polled).
        let registry = InMemoryIntegrationRegistry(
            records: BuiltInIntegrationSeed.records(ecoflowEnabled: true, includeActiveMeasurement: false),
            disabledIntegrations: BuiltInIntegrationSeed.integrationIDs
        )
        let engine = Engine(
            settings: AppSettings(localHost: "router.local", ecoflowEnabled: true),
            integrationRegistry: registry
        )

        let names = await engine.providerDisplayNames()
        let palette = await engine.commandPalette()
        XCTAssertTrue(names.isEmpty, "disabled built-ins must not be registered")
        XCTAssertTrue(palette.isEmpty)
    }

    func testEnablingOneIntegrationRegistersOnlyThatOne() async {
        // Only reachability's integration type is enabled (not in the disabled set).
        let registry = InMemoryIntegrationRegistry(
            records: BuiltInIntegrationSeed.records(ecoflowEnabled: true, includeActiveMeasurement: false),
            disabledIntegrations: BuiltInIntegrationSeed.integrationIDs.subtracting([IntegrationIDs.reachability])
        )
        let engine = Engine(
            settings: AppSettings(localHost: "router.local"),
            integrationRegistry: registry
        )

        let names = await engine.providerDisplayNames()
        XCTAssertEqual(Set(names.keys), [ProviderIDs.reachability])
    }
}
