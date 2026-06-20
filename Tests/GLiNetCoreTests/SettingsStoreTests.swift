import XCTest
@testable import GLiNetCore

final class SettingsStoreTests: XCTestCase {
    func testSettingsPersistNonSecretFieldsOnly() throws {
        let defaults = UserDefaults(suiteName: "GLiNetCoreTests.\(UUID().uuidString)")!
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let settings = AppSettings(
            localHost: "192.168.8.1",
            remoteHost: "router.example.com",
            username: "admin",
            endpointMode: .forceLocal,
            pollInterval: 12,
            speedifyPath: "/tmp/speedify_cli",
            grpcurlPath: "/tmp/grpcurl",
            ecoflowEnabled: true,
            ecoflowHost: "router.local",
            ecoflowPort: 8787
        )

        try store.save(settings)
        let loaded = try store.load()

        XCTAssertEqual(loaded, settings)
        XCTAssertNil(defaults.string(forKey: "routerPassword"))
        XCTAssertNil(defaults.string(forKey: "password"))
    }

    func testSettingsDecodeLegacyPayloadWithoutEcoFlowFields() throws {
        let json = """
        {
          "localHost": "192.168.8.1",
          "remoteHost": "",
          "username": "root",
          "endpointMode": "auto",
          "pollInterval": 5,
          "speedifyPath": "/tmp/speedify_cli",
          "grpcurlPath": "/tmp/grpcurl"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertFalse(settings.ecoflowEnabled)
        XCTAssertEqual(settings.ecoflowHost, "auto")
        XCTAssertEqual(settings.ecoflowPort, 8787)
    }
}
