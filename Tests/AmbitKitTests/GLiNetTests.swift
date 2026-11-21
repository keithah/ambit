import CryptoKit
import Foundation
import Testing
@testable import AmbitKit

@Suite struct GLiNetStatusTests {
    @Test func readsTheOnlineUplinkClientsAndAddress() throws {
        let payload = try json("""
        {"system": {"lan_ip": "192.168.8.1", "uptime": 5103.96},
         "network": [{"interface": "wan", "up": false, "online": false},
                     {"interface": "tethering", "up": true, "online": true}],
         "client": [{"cable_total": 2, "wireless_total": 5}]}
        """)
        let status = GLiNetStatus(systemStatus: payload)
        #expect(status == GLiNetStatus(wan: .tethering, lanIP: "192.168.8.1", clientCount: 7, uptimeSeconds: 5103.96))
    }

    @Test func noOnlineUplinkAndNoClientListAreUnknownNotZero() throws {
        let status = GLiNetStatus(systemStatus: try json(#"{"network": [{"interface": "wan", "up": true, "online": false}]}"#))
        #expect(status.wan == nil)
        #expect(status.clientCount == nil)
    }

    @Test func namesUplinks() {
        #expect(GLiNetWAN(interface: "wan") == .ethernet)
        #expect(GLiNetWAN(interface: "wwan") == .repeater)
        #expect(GLiNetWAN(interface: "modem_0001") == .other("modem_0001"))
        #expect(GLiNetWAN.repeater.text == "Wi-Fi repeater")
    }

    @Test func readsTheFirstVPNTunnel() throws {
        let on = try json(#"{"status_list": [{"tunnel_id": 3, "name": "travel", "enabled": true, "status": 1}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: on) == GLiNetVPN(tunnelID: 3, profile: "travel", isOn: true, isConnected: true))
        let off = try json(#"{"status_list": [{"tunnel_id": 3, "name": "travel", "enabled": false, "status": 1}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: off)?.isConnected == false)
        let failed = try json(#"{"status_list": [{"tunnel_id": 3, "enabled": true, "status": 0}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: failed) == GLiNetVPN(tunnelID: 3, isOn: true, isConnected: false))
        #expect(GLiNetVPN(vpnClientStatus: try json(#"{"status_list": []}"#)) == nil)
    }

    @Test func loginHashWrapsTheCryptedPassword() throws {
        // md5("root:" + crypt + ":nonce1"), with the crypt value from the openssl references.
        let crypted = "$1$abcdefgh$Cq1YRAf.QXEsRsFFce/.F0"
        let expected = Insecure.MD5.hash(data: Data("root:\(crypted):nonce1".utf8)).map { String(format: "%02x", $0) }.joined()
        let hash = try GLiNetClient.loginHash(username: "root", password: "test password", scheme: .md5, salt: "abcdefgh", nonce: "nonce1", method: nil)
        #expect(hash == expected)
        #expect(hash.count == 32)
        let sha = try GLiNetClient.loginHash(username: "root", password: "test password", scheme: .sha512, salt: "abcdefgh", nonce: "nonce1", method: "sha256")
        #expect(sha.count == 64)
        #expect(throws: GLiNetError.unexpectedResponse) {
            try GLiNetClient.loginHash(username: "root", password: "p", scheme: .md5, salt: "abcdefgh", nonce: "n", method: "whirlpool")
        }
    }
}

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

/// A scripted router: each test registers a handler under its own host name, so tests running
/// in parallel do not see each other's requests.
final class FakeRouter: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ method: String, _ params: Any) -> String

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [String]] = [:]

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeRouter.self]
        return URLSession(configuration: configuration)
    }

    /// The RPC methods a host received, in order ("call" entries as "service.method").
    static func calls(host: String) -> [String] { lock.withLock { log[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let body = request.httpBody ?? request.httpBodyStream.map(Self.read),
              let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = message["method"] as? String, let params = message["params"],
              let handler = Self.lock.withLock({ Self.handlers[host] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var name = method
        if method == "call", let list = params as? [Any], list.count == 4 { name = "\(list[1]).\(list[2])" }
        Self.lock.withLock { Self.log[host, default: []].append(name) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(handler(method, params).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Counts across the `@Sendable` handler.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@Suite struct GLiNetClientTests {
    private static let challenge = #"{"id":1,"jsonrpc":"2.0","result":{"alg":5,"salt":"abcdefgh","nonce":"n0nce"}}"#
    private static let statusReply = #"{"jsonrpc":"2.0","result":{"network":[{"interface":"wan","up":true,"online":true}],"client":[{"cable_total":1,"wireless_total":2}]}}"#

    /// What a router that knows the password "test password" expects at login.
    private static func expectedHash() -> String {
        let crypted = "$5$abcdefgh$6tq8p6LhUUVxOuvmdPwyMbL06DwgG.rVrYZ9PbUucj6"
        return Insecure.MD5.hash(data: Data("root:\(crypted):n0nce".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func router(sessions: Counter = Counter(), _ call: @escaping @Sendable (_ sid: String, _ service: String, _ method: String, _ arguments: [String: Any]) -> String) -> FakeRouter.Handler {
        { method, params in
            switch method {
            case "challenge":
                return challenge
            case "login":
                let hash = (params as? [String: Any])?["hash"] as? String
                guard hash == expectedHash() else { return #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"# }
                return #"{"jsonrpc":"2.0","result":{"sid":"sid\#(sessions.next())"}}"#
            default:
                guard let list = params as? [Any], list.count == 4, let sid = list[0] as? String,
                      let service = list[1] as? String, let name = list[2] as? String else { return "{}" }
                return call(sid, service, name, list[3] as? [String: Any] ?? [:])
            }
        }
    }

    private func client(_ host: String, password: String? = "test password", _ handler: @escaping FakeRouter.Handler) throws -> GLiNetClient {
        try GLiNetClient(host: host, password: { password }, session: FakeRouter.session(host: host, handler: handler))
    }

    @Test func logsInOnceAndReadsStatus() async throws {
        let host = "router-ok.test"
        let router = try client(host, Self.router { sid, _, _, _ in
            sid == "sid1" ? Self.statusReply : #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"#
        })
        #expect(try await router.status() == GLiNetStatus(wan: .ethernet, clientCount: 3))
        #expect(try await router.status().clientCount == 3)
        #expect(FakeRouter.calls(host: host) == ["challenge", "login", "system.get_status", "system.get_status"])
    }

    @Test func aWrongPasswordIsReportedAsSuch() async throws {
        let router = try client("router-wrong.test", password: "not it", Self.router { _, _, _, _ in Self.statusReply })
        await #expect(throws: GLiNetError.wrongPassword) { try await router.status() }
    }

    @Test func aMissingPasswordNeverReachesLogin() async throws {
        let host = "router-nopass.test"
        let router = try client(host, password: nil, Self.router { _, _, _, _ in Self.statusReply })
        await #expect(throws: GLiNetError.noPassword) { try await router.status() }
        #expect(FakeRouter.calls(host: host) == ["challenge"])
    }

    @Test func reportsALoginLockout() async throws {
        let router = try client("router-locked.test") { method, _ in
            method == "challenge" ? Self.challenge : #"{"jsonrpc":"2.0","error":{"code":-32003,"message":"locked","data":{"wait":290}}}"#
        }
        await #expect(throws: GLiNetError.lockedOut(seconds: 290)) { try await router.status() }
    }

    @Test func logsInAgainWhenTheSessionExpires() async throws {
        let host = "router-expired.test"
        // The router accepts only the second session, as if it restarted after the first login.
        let router = try client(host, Self.router { sid, _, _, _ in
            sid == "sid2" ? Self.statusReply : #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"#
        })
        #expect(try await router.status().wan == .ethernet)
        #expect(FakeRouter.calls(host: host) == ["challenge", "login", "system.get_status", "challenge", "login", "system.get_status"])
    }

    @Test func switchesTheVPNTunnelItFound() async throws {
        let host = "router-vpn.test"
        let router = try client(host, Self.router { _, service, method, arguments in
            if method == "get_status" { return #"{"jsonrpc":"2.0","result":{"status_list":[{"tunnel_id":4,"name":"home","enabled":false}]}}"# }
            let ok = service == "vpn-client" && (arguments["tunnel_id"] as? NSNumber)?.intValue == 4 && arguments["enabled"] as? Bool == true
            return ok ? #"{"jsonrpc":"2.0","result":[]}"# : #"{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params"}}"#
        })
        #expect(try await router.vpn() == GLiNetVPN(tunnelID: 4, profile: "home", isOn: false, isConnected: false))
        try await router.setVPN(on: true)
        #expect(FakeRouter.calls(host: host).last == "vpn-client.set_tunnel")
    }

    @Test func aRouterWithoutTheVPNServiceHasNoVPN() async throws {
        let router = try client("router-novpn.test", Self.router { _, _, _, _ in
            #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"}}"#
        })
        #expect(try await router.vpn() == nil)
        await #expect(throws: GLiNetError.noVPN) { try await router.setVPN(on: true) }
    }

    @Test func rejectsRepliesThatAreNotJSONRPC() async throws {
        let router = try client("router-garbage.test") { _, _ in "<html>login</html>" }
        await #expect(throws: GLiNetError.unexpectedResponse) { try await router.status() }
        let empty = try client("router-empty.test") { _, _ in "{}" }
        await #expect(throws: GLiNetError.unexpectedResponse) { try await empty.status() }
    }

    @Test func rejectsHostsThatCannotFormAnAddress() {
        for host in ["", "bad host", "a/b", "-flag"] {
            #expect(throws: GLiNetError.invalidHost) { try GLiNetClient(host: host, password: { nil }) }
        }
    }
}
