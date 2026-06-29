import XCTest
@testable import AmbitCore
@testable import AmbitMenuBar

final class IntegrationConfigMigratorTests: XCTestCase {
    func testEmptyRegistrySeedsBuiltInsAndDefaultPingHosts() throws {
        let registry = InMemoryIntegrationRegistry()

        IntegrationConfigMigrator(settings: AppSettings()).migrate(registry)

        let records = try registry.instances()
        XCTAssertEqual(records.first?.id, IntegrationInstanceIDs.systemLocal)
        XCTAssertTrue(records.contains { $0.id == "ping@1.1.1.1:443" })
        XCTAssertTrue(records.contains { $0.id == "ping@8.8.8.8:443" })
        XCTAssertEqual(try registry.disabledIntegrationIDs(), BuiltInIntegrationSeed.integrationIDs)
    }

    func testRetiredPingscopeArtifactsAreDroppedAndPingDefaultsAreReseeded() throws {
        let retired = IntegrationInstanceRecord(
            id: "pingscope@old",
            integrationID: "pingscope",
            displayName: "Old",
            enabled: true
        )
        let retiredBuiltInPing = IntegrationInstanceRecord(
            id: IntegrationInstanceIDs.ping,
            integrationID: IntegrationIDs.ping,
            displayName: "Ping",
            origin: .builtIn
        )
        let system = IntegrationInstanceRecord(
            id: IntegrationInstanceIDs.systemLocal,
            integrationID: IntegrationIDs.system,
            displayName: "System",
            origin: .builtIn
        )
        let registry = InMemoryIntegrationRegistry(
            records: [retired, retiredBuiltInPing, system],
            disabledIntegrations: [IntegrationIDs.ping, IntegrationIDs.glinet]
        )

        IntegrationConfigMigrator(settings: AppSettings()).migrate(registry)

        let records = try registry.instances()
        XCTAssertFalse(records.contains { $0.integrationID == "pingscope" || $0.id == IntegrationInstanceIDs.ping })
        XCTAssertTrue(records.contains { $0.id == IntegrationInstanceIDs.systemLocal })
        XCTAssertTrue(records.contains { $0.id == "ping@1.1.1.1:443" })
        XCTAssertTrue(records.contains { $0.id == "ping@8.8.8.8:443" })
        XCTAssertEqual(try registry.disabledIntegrationIDs(), [IntegrationIDs.glinet])
    }

    func testDuplicatePingHostsByAddressAreDedupedPreservingPrimary() throws {
        let first = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "First", address: "1.1.1.1", method: .tcp, port: 443))
        let primary = IntegrationInstanceRecord(
            id: "ping@primary",
            integrationID: IntegrationIDs.ping,
            displayName: "Primary",
            enabled: true,
            origin: .user,
            config: PingHostConfig(displayName: "Primary", address: "1.1.1.1", method: .tcp, port: 443).asConfigObject()
        )
        let other = IntegrationInstanceRecord.ping(PingHostConfig(displayName: "Google", address: "8.8.8.8", method: .tcp, port: 443))
        let registry = InMemoryIntegrationRegistry(records: [first, primary, other], primary: primary.id)

        IntegrationConfigMigrator(settings: AppSettings()).migrate(registry)

        XCTAssertEqual(try registry.instances().map(\.id), [primary.id, other.id])
        XCTAssertEqual(try registry.primaryInstanceID(), primary.id)
    }
}
