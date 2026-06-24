import XCTest
@testable import AmbitCore

final class IntegrationRegistryTests: XCTestCase {
    private func record(_ id: String, integration: String, enabled: Bool = true, origin: IntegrationInstanceRecord.Origin = .builtIn) -> IntegrationInstanceRecord {
        IntegrationInstanceRecord(
            id: IntegrationInstanceID(rawValue: id),
            integrationID: IntegrationID(rawValue: integration),
            displayName: id,
            enabled: enabled,
            origin: origin
        )
    }

    func testActiveInstancesHonorsBothGranularities() throws {
        let registry = InMemoryIntegrationRegistry(records: [
            record("glinet", integration: "glinet"),
            record("speedify", integration: "speedify", enabled: false),  // instance-disabled
            record("ping@a", integration: "ping", origin: .user),
            record("ping@b", integration: "ping", origin: .user)
        ])
        try registry.setIntegrationEnabled(false, integrationID: "glinet")   // type-disabled

        let active = try registry.activeInstances().map(\.id.rawValue).sorted()
        XCTAssertEqual(active, ["ping@a", "ping@b"])  // glinet type-off, speedify instance-off
    }

    func testInstanceAndIntegrationEnableToggles() throws {
        let registry = InMemoryIntegrationRegistry(records: [record("ping@a", integration: "ping")])

        try registry.setInstanceEnabled(false, instanceID: "ping@a")
        XCTAssertTrue(try registry.activeInstances().isEmpty)
        try registry.setInstanceEnabled(true, instanceID: "ping@a")
        XCTAssertEqual(try registry.activeInstances().count, 1)

        try registry.setIntegrationEnabled(false, integrationID: "ping")
        XCTAssertTrue(try registry.activeInstances().isEmpty)
        try registry.setIntegrationEnabled(true, integrationID: "ping")
        XCTAssertEqual(try registry.activeInstances().count, 1)
    }

    func testUpsertAndRemove() throws {
        let registry = InMemoryIntegrationRegistry()
        try registry.upsert(record("ping@a", integration: "ping"))
        try registry.upsert(record("ping@a", integration: "ping", enabled: false)) // update in place
        XCTAssertEqual(try registry.instances().count, 1)
        XCTAssertEqual(try registry.instance("ping@a")?.enabled, false)
        try registry.remove("ping@a")
        XCTAssertTrue(try registry.instances().isEmpty)
    }

    func testUserDefaultsRegistryRoundTripsInstancesAndDisabledSet() throws {
        let defaults = UserDefaults(suiteName: "IntegrationRegistryTests.\(UUID().uuidString)")!
        let registry = UserDefaultsIntegrationRegistry(defaults: defaults)

        var record = record("ping@a", integration: "ping", origin: .user)
        record.config = ["address": .string("1.1.1.1"), "port": .number(443)]
        try registry.save([record])
        try registry.setDisabledIntegrationIDs(["glinet", "speedify"])

        let reloaded = UserDefaultsIntegrationRegistry(defaults: defaults)
        XCTAssertEqual(try reloaded.instances(), [record])
        XCTAssertEqual(try reloaded.instances().first?.config["address"]?.stringValue, "1.1.1.1")
        XCTAssertEqual(try reloaded.disabledIntegrationIDs(), ["glinet", "speedify"])
    }
}
