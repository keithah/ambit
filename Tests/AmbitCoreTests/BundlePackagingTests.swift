import XCTest

final class BundlePackagingTests: XCTestCase {
    func testLaunchScriptWritesPrivacyUsageStringsForLocationCalendarAndWiFiSSID() throws {
        let script = try readRepoFile(".claude/skills/run-ambit/launch.sh")

        XCTAssertTrue(script.contains("NSLocationWhenInUseUsageDescription"))
        XCTAssertTrue(script.contains("NSCalendarsUsageDescription"))
        XCTAssertTrue(script.contains("NSCalendarsFullAccessUsageDescription"))
        XCTAssertTrue(script.contains("Wi-Fi SSID"))
    }

    func testLaunchScriptSignsBundleWithEntitlements() throws {
        let script = try readRepoFile(".claude/skills/run-ambit/launch.sh")
        let entitlements = try readRepoFile(".claude/skills/run-ambit/Ambit.entitlements")

        XCTAssertTrue(script.contains("--entitlements"))
        XCTAssertTrue(script.contains("Ambit.entitlements"))
        XCTAssertTrue(entitlements.contains("com.apple.security.personal-information.location"))
        XCTAssertTrue(entitlements.contains("com.apple.security.personal-information.calendars"))
        XCTAssertTrue(entitlements.contains("com.apple.security.network.client"))
    }

    func testLaunchScriptRunsAppIntentsMetadataProcessorWhenConstValuesAreAvailable() throws {
        let script = try readRepoFile(".claude/skills/run-ambit/launch.sh")

        XCTAssertTrue(script.contains("appintentsmetadataprocessor"))
        XCTAssertTrue(script.contains("swift-const-vals-list"))
        XCTAssertTrue(script.contains("Metadata.appintents"))
        XCTAssertTrue(script.contains("SWIFT_ENABLE_EMIT_CONST_VALUES"))
    }

    private func readRepoFile(_ relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
