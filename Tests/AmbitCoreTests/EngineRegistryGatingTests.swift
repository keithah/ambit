import XCTest
@testable import AmbitCore

final class EngineRegistryGatingTests: XCTestCase {
    func testLegacyDisabledBuiltInIntegrationsAreNeverRegistered() async {
        // Legacy built-in instance records exist but their integration types are disabled.
        // The always-on local system integration remains enabled by default.
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
        XCTAssertEqual(Set(names.keys), [ProviderIDs.systemOverview])
        XCTAssertTrue(palette.isEmpty)
    }

    func testRegistryAddPlusReloadPicksUpNewPingscopeHost() async {
        // The app's gateway path: add a pingscope host to the registry, then reload.
        let cloudflare = PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443)
        let registry = InMemoryIntegrationRegistry(records: [.ping(cloudflare)])
        let engine = Engine(settings: AppSettings(), integrationRegistry: registry)

        let before = await engine.providerDisplayNames()
        XCTAssertEqual(Set(before.keys), ["ping@1.1.1.1:443/probe"])

        let gateway = PingHostConfig(displayName: "Gateway", address: "192.168.8.1", method: .tcp, port: 80)
        try? registry.upsert(.ping(gateway))
        await engine.reloadProviders()

        let after = await engine.providerDisplayNames()
        XCTAssertEqual(Set(after.keys), ["ping@1.1.1.1:443/probe", "ping@192.168.8.1:80/probe"])
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
        XCTAssertEqual(Set(names.keys), [ProviderIDs.reachability, ProviderIDs.systemOverview])
    }

    func testBuiltInSeedIncludesSystemEnabledAndLegacyDisabledSetExcludesIt() {
        let records = BuiltInIntegrationSeed.records(ecoflowEnabled: false, includeActiveMeasurement: false)

        let system = records.first { $0.id == IntegrationInstanceIDs.systemLocal }
        XCTAssertEqual(system?.integrationID, IntegrationIDs.system)
        XCTAssertEqual(system?.enabled, true)
        XCTAssertFalse(BuiltInIntegrationSeed.integrationIDs.contains(IntegrationIDs.system))
        XCTAssertTrue(BuiltInIntegrationSeed.integrationIDs.contains(IntegrationIDs.glinet))
        XCTAssertTrue(BuiltInIntegrationSeed.integrationIDs.contains(IntegrationIDs.speedify))
        XCTAssertTrue(BuiltInIntegrationSeed.integrationIDs.contains(IntegrationIDs.ecoflow))
        XCTAssertTrue(BuiltInIntegrationSeed.integrationIDs.contains(IntegrationIDs.starlink))
    }

    func testBuiltInRegistryIncludesSystemIntegration() {
        let factory = BuiltInProviderFactory(
            routerClientFactory: { _, _, _ in fatalError("router client not used") },
            systemMetricsReader: FakeRegistrySystemMetricsReader(snapshot: Self.systemSnapshot())
        )

        XCTAssertTrue(factory.integrations().map { $0.id }.contains(IntegrationIDs.system))
    }

    private static func systemSnapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 0, systemPercent: 0, idlePercent: 100, coreCount: 1),
            memory: MemoryMetrics(usedBytes: 0, wiredBytes: 0, compressedBytes: 0, totalBytes: 1)
        )
    }
}

private struct FakeRegistrySystemMetricsReader: SystemMetricsReading {
    var snapshot: SystemMetricsSnapshot
    func snapshot() async throws -> SystemMetricsSnapshot { snapshot }
}
