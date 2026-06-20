import XCTest
@testable import GLiNetCore

final class EndpointSelectionTests: XCTestCase {
    func testParsesDefaultGatewayFromRouteOutput() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.8.1
          interface: en0
        """

        XCTAssertEqual(SystemRouterAddressDiscovery.parseDefaultGateway(from: output), "192.168.8.1")
    }

    func testForcedEndpointBypassesRacing() async throws {
        let selector = EndpointSelector(prober: StubEndpointProber(results: [:]))
        let settings = AppSettings(localHost: "192.168.8.1", remoteHost: "router.example.com", endpointMode: .forceRemote)

        let selection = try await selector.select(settings: settings)

        XCTAssertEqual(selection.mode, .remote)
        XCTAssertEqual(selection.host, "router.example.com")
    }

    func testAutoSelectsFastestSuccessfulChallenge() async throws {
        let selector = EndpointSelector(prober: StubEndpointProber(results: [
            "192.168.8.1": .success(afterNanoseconds: 50_000_000),
            "router.example.com": .success(afterNanoseconds: 5_000_000)
        ]))
        let settings = AppSettings(localHost: "192.168.8.1", remoteHost: "router.example.com", endpointMode: .auto)

        let selection = try await selector.select(settings: settings)

        XCTAssertEqual(selection.mode, .remote)
        XCTAssertEqual(selection.host, "router.example.com")
    }

    func testAutoDiscoversLocalGatewayWhenLocalHostIsBlank() async throws {
        let selector = EndpointSelector(
            prober: StubEndpointProber(results: [
                "192.168.8.1": .success(afterNanoseconds: 1_000_000)
            ]),
            addressDiscovery: StubRouterAddressDiscovery(defaultGateway: "192.168.8.1")
        )
        let settings = AppSettings(localHost: "", remoteHost: "", endpointMode: .auto)

        let selection = try await selector.select(settings: settings)

        XCTAssertEqual(selection.mode, .local)
        XCTAssertEqual(selection.host, "192.168.8.1")
    }

    func testAutoTriesGLiNetFallbackWhenDefaultGatewayIsStarlink() async throws {
        let selector = EndpointSelector(
            prober: StubEndpointProber(results: [
                "192.168.1.1": .failure(afterNanoseconds: 1_000_000),
                "192.168.8.1": .success(afterNanoseconds: 2_000_000)
            ]),
            addressDiscovery: StubRouterAddressDiscovery(defaultGateway: "192.168.1.1")
        )
        let settings = AppSettings(localHost: "auto", remoteHost: "", endpointMode: .auto)

        let selection = try await selector.select(settings: settings)

        XCTAssertEqual(selection.mode, .local)
        XCTAssertEqual(selection.host, "192.168.8.1")
    }

    func testAutoDoesNotSelectNonResponsiveDiscoveredGateway() async throws {
        let selector = EndpointSelector(
            prober: StubEndpointProber(results: [
                "192.168.1.1": .failure(afterNanoseconds: 1_000_000),
                "192.168.8.1": .failure(afterNanoseconds: 1_000_000)
            ]),
            addressDiscovery: StubRouterAddressDiscovery(defaultGateway: "192.168.1.1")
        )
        let settings = AppSettings(localHost: "auto", remoteHost: "", endpointMode: .auto)

        do {
            _ = try await selector.select(settings: settings)
            XCTFail("Expected endpoint selection to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Neither local nor remote router endpoint answered challenge"))
        }
    }

    func testForceLocalDiscoversGatewayWhenLocalHostIsAuto() async throws {
        let selector = EndpointSelector(
            prober: StubEndpointProber(results: [:]),
            addressDiscovery: StubRouterAddressDiscovery(defaultGateway: "192.168.4.1")
        )
        let settings = AppSettings(localHost: "auto", endpointMode: .forceLocal)

        let selection = try await selector.select(settings: settings)

        XCTAssertEqual(selection.mode, .local)
        XCTAssertEqual(selection.host, "192.168.4.1")
    }
}
