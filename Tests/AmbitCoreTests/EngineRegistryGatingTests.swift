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

    func testRegistryAddPlusReloadPicksUpNewPingscopeHost() async {
        // The app's gateway path: add a pingscope host to the registry, then reload.
        let cloudflare = PingScopeHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443)
        let registry = InMemoryIntegrationRegistry(records: [.pingscope(cloudflare)])
        let engine = Engine(settings: AppSettings(), integrationRegistry: registry)

        let before = await engine.providerDisplayNames()
        XCTAssertEqual(Set(before.keys), ["pingscope@1.1.1.1:443/probe"])

        let gateway = PingScopeHostConfig(displayName: "Gateway", address: "192.168.8.1", method: .tcp, port: 80)
        try? registry.upsert(.pingscope(gateway))
        await engine.reloadProviders()

        let after = await engine.providerDisplayNames()
        XCTAssertEqual(Set(after.keys), ["pingscope@1.1.1.1:443/probe", "pingscope@192.168.8.1:80/probe"])
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
