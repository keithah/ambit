import XCTest
@testable import AmbitCore

final class InstalledProviderStoreTests: XCTestCase {
    func testUserDefaultsStorePersistsInstalledManifestProviders() throws {
        let defaults = UserDefaults(suiteName: "InstalledProviderStoreTests.\(UUID().uuidString)")!
        let store = UserDefaultsInstalledProviderStore(defaults: defaults)
        let record = InstalledProviderRecord(
            id: "demo.secure",
            displayName: "Secure Demo",
            packagePath: "/tmp/demo",
            isEnabled: true,
            lastValidation: .valid
        )

        try store.save([record])

        XCTAssertEqual(try store.load(), [record])
    }

    func testStoreUpdatesEnabledStateWithoutDroppingValidation() throws {
        let defaults = UserDefaults(suiteName: "InstalledProviderStoreTests.\(UUID().uuidString)")!
        let store = UserDefaultsInstalledProviderStore(defaults: defaults)
        let record = InstalledProviderRecord(
            id: "demo.secure",
            displayName: "Secure Demo",
            packagePath: "/tmp/demo",
            isEnabled: true,
            lastValidation: .invalid("Missing manifest file")
        )
        try store.save([record])

        try store.setEnabled(false, providerID: "demo.secure")

        XCTAssertEqual(try store.load(), [
            InstalledProviderRecord(
                id: "demo.secure",
                displayName: "Secure Demo",
                packagePath: "/tmp/demo",
                isEnabled: false,
                lastValidation: .invalid("Missing manifest file")
            )
        ])
    }

    func testInstalledProviderStoreInstallsManifestPackageRecord() throws {
        let directory = try Self.writeManifest(id: "demo.install", displayName: "Install Demo")
        let defaults = UserDefaults(suiteName: "InstalledProviderStoreTests.\(UUID().uuidString)")!
        let store = UserDefaultsInstalledProviderStore(defaults: defaults)

        let record = try store.installManifestPackage(at: directory)

        XCTAssertEqual(record.id, "demo.install")
        XCTAssertEqual(record.displayName, "Install Demo")
        XCTAssertEqual(record.packagePath, directory.path)
        XCTAssertEqual(record.isEnabled, true)
        XCTAssertEqual(record.lastValidation, .valid)
        XCTAssertEqual(try store.load(), [record])
    }

    private static func writeManifest(id: String, displayName: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambit-install-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "pollInterval": 30,
          "endpoint": { "method": "GET", "url": "https://example.test/status" },
          "metrics": [],
          "commands": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
