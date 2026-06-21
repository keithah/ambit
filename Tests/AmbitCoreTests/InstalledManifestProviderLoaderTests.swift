import XCTest
@testable import AmbitCore

final class InstalledManifestProviderLoaderTests: XCTestCase {
    func testLoadsEnabledValidManifestProviders() throws {
        let directory = try Self.writeManifest(id: "demo.secure", displayName: "Secure Demo")
        let store = InMemoryInstalledProviderStore(records: [
            InstalledProviderRecord(id: "demo.secure", displayName: "Secure Demo", packagePath: directory.path, isEnabled: true)
        ])
        let loader = InstalledManifestProviderLoader(store: store, credentialStore: StaticCredentialStore(credentials: [:]))

        let result = try loader.load()

        XCTAssertEqual(result.records.map(\.id), ["demo.secure"])
        XCTAssertEqual(result.providers.map(\.id), ["demo.secure"])
        XCTAssertEqual(result.records.first?.lastValidation, .valid)
    }

    func testKeepsInvalidRecordsButDoesNotCreateProvider() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = InMemoryInstalledProviderStore(records: [
            InstalledProviderRecord(id: "demo.missing", displayName: "Missing Demo", packagePath: directory.path, isEnabled: true)
        ])
        let loader = InstalledManifestProviderLoader(store: store, credentialStore: StaticCredentialStore(credentials: [:]))

        let result = try loader.load()

        XCTAssertEqual(result.providers.count, 0)
        XCTAssertEqual(result.records.first?.id, "demo.missing")
        if case .invalid(let message) = result.records.first?.lastValidation {
            XCTAssertTrue(message.contains("Manifest file is missing"))
        } else {
            XCTFail("Expected invalid validation result")
        }
    }

    func testCompilesAlertRulesFromInstalledManifestProviders() throws {
        let directory = try Self.writeManifest(
            id: "demo.alerts",
            displayName: "Alerts Demo",
            extraJSON: #""alerts": [{"id": "battery.low", "metricID": "ok", "kind": { "type": "threshold", "comparison": "lessThan", "value": 1 }, "title": "Battery low", "message": "Battery is low.", "severity": "warning"}],"#
        )
        let store = InMemoryInstalledProviderStore(records: [
            InstalledProviderRecord(id: "demo.alerts", displayName: "Alerts Demo", packagePath: directory.path, isEnabled: true)
        ])
        let loader = InstalledManifestProviderLoader(store: store, credentialStore: StaticCredentialStore(credentials: [:]))

        let result = try loader.load()

        XCTAssertEqual(result.alertRules, [
            .threshold(ThresholdAlertRule(
                id: "demo.alerts.battery.low",
                providerID: "demo.alerts",
                metricID: "ok",
                comparison: .lessThan,
                threshold: 1,
                title: "Battery low",
                message: "Battery is low.",
                severity: .warning
            ))
        ])
    }

    private static func writeManifest(id: String, displayName: String, extraJSON: String = "") throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambit-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "pollInterval": 30,
          "endpoint": { "method": "GET", "url": "https://example.test/status" },
          "metrics": [
            { "id": "ok", "label": "OK", "value": { "type": "bool", "path": "ok" } }
          ],
          \(extraJSON)
          "commands": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}

private final class InMemoryInstalledProviderStore: InstalledProviderStore, @unchecked Sendable {
    var records: [InstalledProviderRecord]

    init(records: [InstalledProviderRecord]) {
        self.records = records
    }

    func load() throws -> [InstalledProviderRecord] {
        records
    }

    func save(_ records: [InstalledProviderRecord]) throws {
        self.records = records
    }
}
