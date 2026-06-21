import XCTest
@testable import AmbitCore

final class ProviderSetupSummaryTests: XCTestCase {
    func testValidProviderWithMissingRequiredCredentialNeedsCredentials() throws {
        let directory = try Self.writeManifest(
            id: "demo.secure",
            displayName: "Secure Demo",
            credentialsJSON: """
            [
              { "id": "api_token", "label": "API Token", "kind": "bearerToken", "required": true },
              { "id": "region", "label": "Region", "kind": "header", "required": false }
            ]
            """
        )
        let record = InstalledProviderRecord(
            id: "demo.secure",
            displayName: "Secure Demo",
            packagePath: directory.path,
            lastValidation: .valid
        )

        let summary = ProviderSetupSummary.make(record: record, credentialStore: StaticCredentialStore(credentials: [:]))

        XCTAssertEqual(summary.status, .needsCredentials)
        XCTAssertEqual(summary.statusText, "Missing required credentials")
        XCTAssertEqual(summary.credentials, [
            ProviderCredentialSetupSummary(
                id: "api_token",
                label: "API Token",
                kind: "bearerToken",
                isRequired: true,
                isConfigured: false
            ),
            ProviderCredentialSetupSummary(
                id: "region",
                label: "Region",
                kind: "header",
                isRequired: false,
                isConfigured: false
            )
        ])
        XCTAssertEqual(summary.primaryAction, .saveCredentials)
    }

    func testRequiredCredentialConfiguredIsReady() throws {
        let directory = try Self.writeManifest(
            id: "demo.ready",
            displayName: "Ready Demo",
            credentialsJSON: """
            [
              { "id": "api_token", "label": "API Token", "kind": "bearerToken", "required": true }
            ]
            """
        )
        let record = InstalledProviderRecord(
            id: "demo.ready",
            displayName: "Ready Demo",
            packagePath: directory.path,
            lastValidation: .valid
        )
        let store = StaticCredentialStore.manifestCredentials(
            providerID: "demo.ready",
            values: ["api_token": "configured-token"]
        )

        let summary = ProviderSetupSummary.make(record: record, credentialStore: store)

        XCTAssertEqual(summary.status, .ready)
        XCTAssertEqual(summary.statusText, "Ready")
        XCTAssertEqual(summary.credentials.first?.isConfigured, true)
        XCTAssertEqual(summary.primaryAction, .refreshValidation)
    }

    func testInvalidRecordUsesSingleLineValidationMessageAndNoCredentials() {
        let record = InstalledProviderRecord(
            id: "demo.invalid",
            displayName: "Invalid Demo",
            packagePath: "/tmp/missing",
            lastValidation: .invalid("Manifest file\n\nis missing")
        )

        let summary = ProviderSetupSummary.make(record: record, credentialStore: StaticCredentialStore(credentials: [:]))

        XCTAssertEqual(summary.status, .invalid)
        XCTAssertEqual(summary.statusText, "Manifest file is missing")
        XCTAssertEqual(summary.credentials, [])
        XCTAssertEqual(summary.primaryAction, .refreshValidation)
    }

    func testDisabledValidProviderIsDisabled() throws {
        let directory = try Self.writeManifest(id: "demo.disabled", displayName: "Disabled Demo")
        let record = InstalledProviderRecord(
            id: "demo.disabled",
            displayName: "Disabled Demo",
            packagePath: directory.path,
            isEnabled: false,
            lastValidation: .valid
        )

        let summary = ProviderSetupSummary.make(record: record, credentialStore: StaticCredentialStore(credentials: [:]))

        XCTAssertEqual(summary.status, .disabled)
        XCTAssertEqual(summary.statusText, "Disabled")
    }

    private static func writeManifest(
        id: String,
        displayName: String,
        credentialsJSON: String = "[]"
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambit-provider-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "pollInterval": 30,
          "credentials": \(credentialsJSON),
          "endpoint": { "method": "GET", "url": "https://example.test/status" },
          "metrics": [
            { "id": "ok", "label": "OK", "value": { "type": "bool", "path": "ok" } }
          ],
          "commands": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
