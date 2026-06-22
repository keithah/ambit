import XCTest
@testable import AmbitCore

final class IntegrationIdentityTests: XCTestCase {
    func testRouterAndVPNShareTheGLiNetIntegration() {
        let router = GLiNetRouterProvider()
        let vpn = GLiNetVPNProvider()

        // One install (gl.inet) stands up two providers sharing the integration instance.
        XCTAssertEqual(router.integrationID, IntegrationIDs.glinet)
        XCTAssertEqual(vpn.integrationID, IntegrationIDs.glinet)
        XCTAssertEqual(router.integrationID, vpn.integrationID)
        XCTAssertEqual(router.integrationInstanceID, vpn.integrationInstanceID)

        // ...but they remain two distinct providers/types.
        XCTAssertEqual(router.typeID, ProviderIDs.router)
        XCTAssertEqual(vpn.typeID, ProviderIDs.vpn)
        XCTAssertNotEqual(router.instanceID, vpn.instanceID)
    }

    func testBuiltInInstanceIDsAreScopedUnderTheirIntegrationInstance() {
        let builtIns: [any Provider] = [
            GLiNetRouterProvider(),
            GLiNetVPNProvider(),
            ReachabilityProvider(),
            SpeedifyProvider(),
            StarlinkProvider(),
            EcoFlowProvider(),
            PingProvider(),
            Iperf3Provider()
        ]

        for provider in builtIns {
            XCTAssertEqual(
                provider.instanceID.rawValue,
                "\(provider.integrationInstanceID.rawValue)/\(provider.typeID)",
                "\(provider.id) instance id should be scoped under its integration instance"
            )
        }
    }

    func testSingleProviderIntegrationsAreTheDegenerateScopedCase() {
        XCTAssertEqual(SpeedifyProvider().instanceID, ProviderInstanceIDs.speedify) // "speedify/speedify"
        XCTAssertEqual(StarlinkProvider().instanceID, ProviderInstanceIDs.starlink)
        XCTAssertEqual(EcoFlowProvider().instanceID, ProviderInstanceIDs.ecoflow)
    }

    func testDefaultInstanceIDForNonBuiltInProviderIsBare() {
        struct DemoProvider: Provider {
            let id: ProviderID = "demo.thing"
            let displayName = "Demo"
            let pollInterval: TimeInterval = 5
            func poll(context: EnvironmentContext) async -> ProviderSnapshot { ProviderSnapshot() }
        }

        let demo = DemoProvider()
        XCTAssertEqual(demo.instanceID, ProviderInstanceID(rawValue: "demo.thing"))
        XCTAssertEqual(demo.typeID, "demo.thing")
        XCTAssertEqual(demo.integrationID, IntegrationID(rawValue: "demo.thing"))
    }
}
