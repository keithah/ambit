import XCTest

final class BundlePackagingTests: XCTestCase {
    func testLaunchScriptWritesPrivacyUsageStringsForLocationCalendarAndWiFiSSID() throws {
        let script = try readRepoFile(".claude/skills/run-ambit/launch.sh")

        XCTAssertTrue(script.contains("CFBundleIdentifier</key><string>com.hadm.ambit</string>"))
        XCTAssertTrue(script.contains("NSLocationWhenInUseUsageDescription"))
        XCTAssertTrue(script.contains("NSLocationUsageDescription"))
        XCTAssertTrue(script.contains("NSCalendarsUsageDescription"))
        XCTAssertTrue(script.contains("NSCalendarsFullAccessUsageDescription"))
        XCTAssertTrue(script.contains("Wi-Fi SSID"))
    }

    func testLaunchScriptSignsBundleWithEntitlements() throws {
        let script = try readRepoFile(".claude/skills/run-ambit/launch.sh")
        let entitlements = try readRepoFile(".claude/skills/run-ambit/Ambit.entitlements")

        XCTAssertTrue(script.contains("--entitlements"))
        XCTAssertTrue(script.contains("Ambit.entitlements"))
        XCTAssertTrue(script.contains("AMBIT_CODESIGN_IDENTITY"))
        XCTAssertTrue(script.contains("Apple Development:"))
        XCTAssertFalse(script.contains("com.apple.developer.networking.wifi-info"))
        XCTAssertTrue(entitlements.contains("com.apple.security.personal-information.location"))
        XCTAssertTrue(entitlements.contains("com.apple.security.personal-information.calendars"))
        XCTAssertTrue(entitlements.contains("com.apple.security.network.client"))
        XCTAssertFalse(entitlements.contains("com.apple.developer.networking.wifi-info"))
    }

    func testLaunchScriptRunsAppIntentsMetadataProcessorWhenConstValuesAreAvailable() throws {
        let script = try readRepoFile(".claude/skills/run-ambit/launch.sh")

        XCTAssertTrue(script.contains("xcodebuild -scheme Ambit"))
        XCTAssertTrue(script.contains("SWIFT_ENABLE_EMIT_CONST_VALUES=YES"))
        XCTAssertTrue(script.contains("CODE_SIGNING_ALLOWED=NO"))
        XCTAssertTrue(script.contains("appintentsmetadataprocessor"))
        XCTAssertTrue(script.contains("swift-const-vals-list"))
        XCTAssertTrue(script.contains("Metadata.appintents"))
        XCTAssertTrue(script.contains("appintentsmetadataprocessor.log"))
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
