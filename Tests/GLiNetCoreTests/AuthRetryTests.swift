import XCTest
@testable import GLiNetCore

final class AuthRetryTests: XCTestCase {
    func testCallRetriesOnceAfterSessionFailure() async throws {
        let transport = MockRouterTransport()
        transport.responses = [
            .challenge(alg: 6, salt: "salt", nonce: "nonce-1"),
            .login(sid: "expired"),
            .rpcError(code: -32000, message: "Access denied"),
            .challenge(alg: 6, salt: "salt", nonce: "nonce-2"),
            .login(sid: "fresh"),
            .result(["status": .string("ok")])
        ]
        let client = GLiNetClient(
            endpoint: URL(string: "http://192.168.8.1/rpc")!,
            username: "root",
            passwordProvider: { "password" },
            transport: transport
        )

        let result = try await client.call(service: "system", method: "get_status")

        XCTAssertEqual(result["status"], .string("ok"))
        XCTAssertEqual(transport.calledMethods, ["challenge", "login", "call", "challenge", "login", "call"])
    }

    func testReusedClientKeepsSessionAcrossCalls() async throws {
        let transport = MockRouterTransport()
        transport.responses = [
            .challenge(alg: 6, salt: "salt", nonce: "nonce-1"),
            .login(sid: "sid-1"),
            .result(["status": .string("ok")]),
            .result(["running": .bool(true)])
        ]
        let client = GLiNetClient(
            endpoint: URL(string: "http://192.168.8.1/rpc")!,
            username: "root",
            passwordProvider: { "password" },
            transport: transport
        )

        _ = try await client.call(service: "system", method: "get_status")
        _ = try await client.call(service: "wg-client", method: "get_status")

        XCTAssertEqual(transport.calledMethods, ["challenge", "login", "call", "call"])
    }

    func testVPNStatusReturnsUnavailableWhenFirmwareDoesNotExposeVPNMethods() async throws {
        let transport = MockRouterTransport()
        transport.responses = [
            .challenge(alg: 6, salt: "salt", nonce: "nonce-1"),
            .login(sid: "sid-1"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found"),
            .rpcError(code: -32601, message: "Method not found")
        ]
        let client = GLiNetClient(
            endpoint: URL(string: "http://192.168.8.1/rpc")!,
            username: "root",
            passwordProvider: { "password" },
            transport: transport
        )

        let status = try await client.vpnStatus()

        XCTAssertFalse(status.isAvailable)
        XCTAssertFalse(status.isConnected)
        XCTAssertEqual(status.unavailableReason, "No supported VPN service API is active on this firmware.")
    }
}
