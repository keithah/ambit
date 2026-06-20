import XCTest
@testable import GLiNetCore

final class VPNDiscoveryTests: XCTestCase {
    func testUsesVPNClientDashboardAPIBeforeLegacyClientAPIs() async throws {
        let transport = MockRouterTransport()
        transport.responses = [
            .challenge(alg: 6, salt: "salt", nonce: "nonce-1"),
            .login(sid: "sid-1"),
            .result([
                "mode": .number(0),
                "status_list": .array([
                    .object(["enabled": .bool(false), "tunnel_id": .number(10), "name": .string("Primary Tunnel")])
                ])
            ]),
            .result([
                "global_enabled": .bool(false),
                "tunnels": .array([
                    .object(["enabled": .bool(false), "tunnel_id": .number(10), "name": .string("Primary Tunnel")])
                ])
            ]),
            .result(["configs": .object(["wireguard": .array([]), "openvpn": .array([])])])
        ]
        let client = GLiNetClient(
            endpoint: URL(string: "http://192.168.8.1/rpc")!,
            username: "root",
            passwordProvider: { "password" },
            transport: transport
        )

        let status = try await client.vpnStatus()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.vpnProtocol, .vpnClient)
        XCTAssertEqual(status.profile, "Primary Tunnel")
        XCTAssertFalse(status.isConnected)
        XCTAssertFalse(status.canToggle)
        XCTAssertEqual(status.unavailableReason, "No VPN client configuration selected.")
        XCTAssertEqual(transport.calledMethods, ["challenge", "login", "call", "call", "call"])
    }

    func testDiscoversActiveTailscaleWhenClientAPIsAreMissing() async throws {
        let transport = MockRouterTransport()
        transport.responses = [
            .challenge(alg: 6, salt: "salt", nonce: "nonce-1"),
            .login(sid: "sid-1"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .result(["status": .number(2), "dns": .string("tailnet.example.ts.net")])
        ]
        let client = GLiNetClient(
            endpoint: URL(string: "http://192.168.8.1/rpc")!,
            username: "root",
            passwordProvider: { "password" },
            transport: transport
        )

        let status = try await client.vpnStatus()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.vpnProtocol, .tailscale)
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.server, "tailnet.example.ts.net")
    }

    func testDiscoversActiveWireGuardServerWhenTailscaleInactive() async throws {
        let transport = MockRouterTransport()
        transport.responses = [
            .challenge(alg: 6, salt: "salt", nonce: "nonce-1"),
            .login(sid: "sid-1"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .result(["status": .number(0)]),
            .result(["status": .number(0)]),
            .result(["server": .object(["status": .number(1)]), "peers": .array([])])
        ]
        let client = GLiNetClient(
            endpoint: URL(string: "http://192.168.8.1/rpc")!,
            username: "root",
            passwordProvider: { "password" },
            transport: transport
        )

        let status = try await client.vpnStatus()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.vpnProtocol, .wireGuardServer)
        XCTAssertTrue(status.isConnected)
    }

    func testDiscoversActiveTorWhenClientAPIsAreMissing() async throws {
        let transport = MockRouterTransport()
        transport.responses = [
            .challenge(alg: 6, salt: "salt", nonce: "nonce-1"),
            .login(sid: "sid-1"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .result(["status": .number(0)]),
            .result(["status": .number(1), "country": .string("United States")])
        ]
        let client = GLiNetClient(
            endpoint: URL(string: "http://192.168.8.1/rpc")!,
            username: "root",
            passwordProvider: { "password" },
            transport: transport
        )

        let status = try await client.vpnStatus()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.vpnProtocol, .tor)
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.server, "United States")
    }
}
