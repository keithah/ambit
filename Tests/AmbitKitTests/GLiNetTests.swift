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
        #expect(GLiNetWAN(interface: "modem_0001") == .cellular)
        #expect(GLiNetWAN(interface: "br-guest") == .other("br-guest"))
        #expect(GLiNetWAN.repeater.text == "Wi-Fi repeater")
        // A raw interface name never reaches the screen.
        #expect(GLiNetWAN.other("br-guest").text == "Other connection")
    }

    @Test func readsTheFirstVPNTunnel() throws {
        let on = try json(#"{"status_list": [{"tunnel_id": 3, "name": "travel", "enabled": true, "status": 1}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: on) == GLiNetVPN(tunnelID: 3, profile: "travel", isOn: true, isConnected: true))
        let off = try json(#"{"status_list": [{"tunnel_id": 3, "name": "travel", "enabled": false, "status": 1}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: off)?.isConnected == false)
        let failed = try json(#"{"status_list": [{"tunnel_id": 3, "enabled": true, "status": 0}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: failed) == GLiNetVPN(tunnelID: 3, isOn: true, isConnected: false))
        #expect(GLiNetVPN(vpnClientStatus: try json(#"{"status_list": []}"#)) == nil)
        // Switched on, but the router has not said it is up.
        let silent = try json(#"{"status_list": [{"tunnel_id": 3, "enabled": true}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: silent) == GLiNetVPN(tunnelID: 3, isOn: true, isConnected: false))
        // Of several profiles, the one switched on is the one in use.
        let two = try json(#"{"status_list": [{"tunnel_id": 1, "name": "a", "enabled": false}, {"tunnel_id": 2, "name": "b", "enabled": true, "status": 1}]}"#)
        #expect(GLiNetVPN(vpnClientStatus: two) == GLiNetVPN(tunnelID: 2, profile: "b", isOn: true, isConnected: true))
    }

    @Test func loginHashWrapsTheCryptedPassword() throws {
        // md5("root:" + crypt + ":nonce1"), with the crypt value from the openssl references.
        let crypted = "$1$abcdefgh$Cq1YRAf.QXEsRsFFce/.F0"
        let expected = Insecure.MD5.hash(data: Data("root:\(crypted):nonce1".utf8)).map { String(format: "%02x", $0) }.joined()
        let hash = try GLiNetClient.loginHash(username: "root", password: "test password", scheme: .md5, salt: "abcdefgh", nonce: "nonce1", method: nil)
        #expect(hash == expected)
        #expect(hash.count == 32)
        let sha = try GLiNetClient.loginHash(username: "root", password: "test password", scheme: .sha512, salt: "abcdefgh", nonce: "nonce1", method: "sha256")
        let cryptedSHA = "$6$abcdefgh$B5Cs2daEj8iFUqSTHSxQ.9WcRJs7uzueVHU./UjUW9NIyxpQMyNXeL2L4003eI9nLbCeL7Wf/t7EPEvP.IZZO0"
        #expect(sha == SHA256.hash(data: Data("root:\(cryptedSHA):nonce1".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(throws: GLiNetError.wrongPassword) {
            try GLiNetClient.loginHash(username: "root", password: String(repeating: "x", count: 257), scheme: .md5, salt: "abcdefgh", nonce: "n", method: nil)
        }
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
    /// Returns the reply body, or nil to never answer.
    typealias Handler = @Sendable (_ method: String, _ params: Any) -> String?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [String]] = [:]
    nonisolated(unsafe) private static var holds: [String: (name: String, occurrence: Int)] = [:]
    nonisolated(unsafe) private static var held: [String: @Sendable () -> Void] = [:]

    /// Keeps back the reply to the nth request of that name until `release(host:)`.
    static func hold(host: String, name: String, occurrence: Int) {
        lock.withLock { holds[host] = (name, occurrence) }
    }

    static func isHolding(host: String) -> Bool { lock.withLock { held[host] != nil } }

    static func release(host: String) {
        let deliver = lock.withLock { held.removeValue(forKey: host) }
        deliver?()
    }

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
        let seen = Self.lock.withLock {
            Self.log[host, default: []].append(name)
            return Self.log[host, default: []].filter { $0 == name }.count
        }
        guard let reply = handler(method, params) else { return }
        let deliver: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let parked = Self.lock.withLock {
            guard let hold = Self.holds[host], hold.name == name, hold.occurrence == seen else { return false }
            Self.holds[host] = nil
            Self.held[host] = deliver
            return true
        }
        if !parked { deliver() }
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

/// A value shared with a `@Sendable` closure.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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

    @Test func aWrongPasswordIsTriedOnceUntilItChanges() async throws {
        // The router locks its login after a few failures, and status() is polled.
        let host = "router-wrong.test"
        let password = Box("not it")
        let router = try GLiNetClient(host: host, password: { password.value }, session: FakeRouter.session(host: host, handler: Self.router { _, _, _, _ in Self.statusReply }))
        for _ in 0..<4 {
            await #expect(throws: GLiNetError.wrongPassword) { try await router.status() }
        }
        #expect(FakeRouter.calls(host: host) == ["challenge", "login"])
        password.value = "test password"
        #expect(try await router.status().clientCount == 3)
        #expect(FakeRouter.calls(host: host).filter { $0 == "login" }.count == 2)
    }

    @Test func aLockoutIsWaitedOutWithoutAskingAgain() async throws {
        let host = "router-lockwait.test"
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let locked = Box(true)
        let inner = Self.router { _, _, _, _ in Self.statusReply }
        let handler: FakeRouter.Handler = { method, params in
            method == "login" && locked.value ? #"{"jsonrpc":"2.0","error":{"code":-32003,"message":"locked","data":{"wait":290}}}"# : inner(method, params)
        }
        let router = try GLiNetClient(host: host, password: { "test password" }, session: FakeRouter.session(host: host, handler: handler), now: { clock.value })
        await #expect(throws: GLiNetError.lockedOut(seconds: 290)) { try await router.status() }
        clock.value += 100
        await #expect(throws: GLiNetError.lockedOut(seconds: 190)) { try await router.status() }
        #expect(FakeRouter.calls(host: host) == ["challenge", "login"])
        clock.value += 191
        locked.value = false
        #expect(try await router.status().clientCount == 3)
    }

    @Test func callsThatStartTogetherShareOneLogin() async throws {
        let host = "router-together.test"
        let router = try client(host, Self.router { _, service, _, _ in
            service == "system" ? Self.statusReply : #"{"jsonrpc":"2.0","result":{"status_list":[]}}"#
        })
        async let first = router.status()
        async let second = router.status()
        async let third = router.vpn()
        _ = try await (first, second, third)
        #expect(FakeRouter.calls(host: host).filter { $0 == "login" }.count == 1)
        #expect(FakeRouter.calls(host: host).filter { $0 == "challenge" }.count == 1)
    }

    @Test func aCallTheRouterAlwaysDeniesStopsOpeningSessions() async throws {
        let host = "router-denies.test"
        let router = try client(host, Self.router { _, _, _, _ in
            #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"#
        })
        for _ in 0..<3 {
            await #expect(throws: GLiNetError.accessDenied) { try await router.status() }
        }
        #expect(FakeRouter.calls(host: host) == ["challenge", "login", "system.get_status", "challenge", "login", "system.get_status"])
    }

    @Test func twoDeniedCallsPolledInTurnDoNotOpenSessionsForever() async throws {
        let host = "router-denies-two.test"
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let handler = Self.router { _, _, _, _ in #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"# }
        let router = try GLiNetClient(host: host, password: { "test password" }, session: FakeRouter.session(host: host, handler: handler), now: { clock.value })
        for _ in 0..<10 {
            await #expect(throws: GLiNetError.accessDenied) { try await router.status() }
            await #expect(throws: GLiNetError.accessDenied) { _ = try await router.vpn() }
        }
        // One login to start, one retry for each of the two calls, then silence.
        #expect(FakeRouter.calls(host: host).filter { $0 == "login" }.count == 3)
        let before = FakeRouter.calls(host: host).count
        // Later the call is tried again, in case the router changed its mind.
        clock.value += GLiNetClient.deniedCallDelay + 1
        await #expect(throws: GLiNetError.accessDenied) { try await router.status() }
        #expect(FakeRouter.calls(host: host).count > before)
    }

    @Test func aDenialThatArrivesAfterTheSessionWasReplacedStillStopsTheCall() async throws {
        let host = "router-denies-late.test"
        let router = try client(host, Self.router { _, _, _, _ in
            #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"#
        })
        // status() is denied, logs in again, and its retry stays unanswered for now.
        FakeRouter.hold(host: host, name: "system.get_status", occurrence: 2)
        async let late: Void = { _ = try? await router.status() }()
        for _ in 0..<2_000 where !FakeRouter.isHolding(host: host) { try await Task.sleep(for: .milliseconds(1)) }
        try #require(FakeRouter.isHolding(host: host))
        // Meanwhile vpn() is denied too and replaces the session.
        await #expect(throws: GLiNetError.accessDenied) { _ = try await router.vpn() }
        FakeRouter.release(host: host)
        await late
        let before = FakeRouter.calls(host: host)
        await #expect(throws: GLiNetError.accessDenied) { try await router.status() }
        #expect(FakeRouter.calls(host: host) == before)
    }

    @Test func aDenialThatArrivesAfterTheSameCallSucceededIsNotKept() async throws {
        let host = "router-denies-then-works.test"
        // Only the third session is accepted.
        let router = try client(host, Self.router { sid, _, _, _ in
            sid == "sid3" ? Self.statusReply : #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"#
        })
        FakeRouter.hold(host: host, name: "system.get_status", occurrence: 2)
        async let late: Void = { _ = try? await router.status() }()
        for _ in 0..<2_000 where !FakeRouter.isHolding(host: host) { try await Task.sleep(for: .milliseconds(1)) }
        try #require(FakeRouter.isHolding(host: host))
        #expect(try await router.status().clientCount == 3)
        FakeRouter.release(host: host)
        await late
        #expect(try await router.status().clientCount == 3)
    }

    @Test func aSuccessThatArrivesAfterADenialClearsIt() async throws {
        let host = "router-works-late.test"
        // The second and third requests are denied; the others succeed.
        let requests = Counter()
        let router = try client(host, Self.router { _, _, _, _ in
            (2...3).contains(requests.next()) ? #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"# : Self.statusReply
        })
        FakeRouter.hold(host: host, name: "system.get_status", occurrence: 1)
        async let late = router.status()
        for _ in 0..<2_000 where !FakeRouter.isHolding(host: host) { try await Task.sleep(for: .milliseconds(1)) }
        try #require(FakeRouter.isHolding(host: host))
        await #expect(throws: GLiNetError.accessDenied) { try await router.status() }
        FakeRouter.release(host: host)
        #expect(try await late.clientCount == 3)
        #expect(try await router.status().clientCount == 3)
    }

    @Test func aDenialFromBeforeAPasswordChangeIsNotKept() async throws {
        let host = "router-denies-old-password.test"
        let password = Box("test password")
        let handler = Self.router { _, _, _, _ in #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"# }
        let router = try GLiNetClient(host: host, password: { password.value }, session: FakeRouter.session(host: host, handler: handler))
        FakeRouter.hold(host: host, name: "system.get_status", occurrence: 2)
        async let late: Void = { _ = try? await router.status() }()
        for _ in 0..<2_000 where !FakeRouter.isHolding(host: host) { try await Task.sleep(for: .milliseconds(1)) }
        try #require(FakeRouter.isHolding(host: host))
        // The password changes while the retry is unanswered; the next login uses the new one.
        password.value = "another password"
        await #expect(throws: GLiNetError.wrongPassword) { _ = try await router.vpn() }
        FakeRouter.release(host: host)
        await late
        // The late denial belongs to the old password, so it must not hide the real problem.
        await #expect(throws: GLiNetError.wrongPassword) { try await router.status() }
    }

    @Test func aRefusedChallengeDoesNotCondemnThePassword() async throws {
        let host = "router-challenge-denied.test"
        let refuse = Box(true)
        let inner = Self.router { _, _, _, _ in Self.statusReply }
        let router = try client(host) { method, params in
            method == "challenge" && refuse.value ? #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"# : inner(method, params)
        }
        await #expect(throws: GLiNetError.rpc(code: -32000, message: "Access denied")) { try await router.status() }
        refuse.value = false
        #expect(try await router.status().clientCount == 3)
    }

    @Test func aLoginThatFailsForAnUnknownReasonIsNotRepeatedAtOnce() async throws {
        let host = "router-login-garbage.test"
        let clock = Box(Date(timeIntervalSince1970: 1_000))
        let broken = Box(true)
        let inner = Self.router { _, _, _, _ in Self.statusReply }
        let handler: FakeRouter.Handler = { method, params in
            method == "login" && broken.value ? #"{"jsonrpc":"2.0","error":{"code":-1,"message":"busy"}}"# : inner(method, params)
        }
        let router = try GLiNetClient(host: host, password: { "test password" }, session: FakeRouter.session(host: host, handler: handler), now: { clock.value })
        for _ in 0..<3 {
            await #expect(throws: GLiNetError.rpc(code: -1, message: "busy")) { try await router.status() }
        }
        #expect(FakeRouter.calls(host: host) == ["challenge", "login"])
        broken.value = false
        clock.value += GLiNetClient.loginRetryDelay + 1
        #expect(try await router.status().clientCount == 3)
    }

    @Test func aLockoutWithoutAUsableWaitUsesTheDefault() async throws {
        for (index, data) in [#""data":{"wait":0}"#, #""data":{}"#].enumerated() {
            let host = "router-lock-default-\(index).test"
            let clock = Box(Date(timeIntervalSince1970: 1_000))
            let handler: FakeRouter.Handler = { method, _ in
                method == "challenge" ? Self.challenge : #"{"jsonrpc":"2.0","error":{"code":-32003,"message":"locked",\#(data)}}"#
            }
            let router = try GLiNetClient(host: host, password: { "test password" }, session: FakeRouter.session(host: host, handler: handler), now: { clock.value })
            await #expect(throws: GLiNetError.self) { try await router.status() }
            clock.value += GLiNetClient.defaultLockout - 10
            await #expect(throws: GLiNetError.lockedOut(seconds: 10)) { try await router.status() }
            #expect(FakeRouter.calls(host: host) == ["challenge", "login"])
        }
    }

    @Test func cancellingTheCallerEndsTheCall() async throws {
        let host = "router-cancelled.test"
        let router = try GLiNetClient(host: host, password: { "test password" }, session: FakeRouter.session(host: host) { _, _ in nil }, timeout: 1)
        let task = Task { try await router.status() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func usesTheOuterHashTheRouterNames() async throws {
        let crypted = "$5$abcdefgh$6tq8p6LhUUVxOuvmdPwyMbL06DwgG.rVrYZ9PbUucj6"
        let expected = SHA256.hash(data: Data("root:\(crypted):n0nce".utf8)).map { String(format: "%02x", $0) }.joined()
        let router = try client("router-sha.test") { method, params in
            switch method {
            case "challenge": return #"{"jsonrpc":"2.0","result":{"alg":5,"salt":"abcdefgh","nonce":"n0nce","hash-method":"sha256"}}"#
            case "login":
                let ok = (params as? [String: Any])?["hash"] as? String == expected
                return ok ? #"{"jsonrpc":"2.0","result":{"sid":"s"}}"# : #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access denied"}}"#
            default: return Self.statusReply
            }
        }
        #expect(try await router.status().clientCount == 3)
    }

    @Test func givesUpAfterTheTimeout() async throws {
        let host = "router-slow.test"
        let session = FakeRouter.session(host: host) { _, _ in nil }
        let router = try GLiNetClient(host: host, password: { "test password" }, session: session, timeout: 0.2)
        await #expect(throws: GLiNetError.timedOut) { try await router.status() }
    }

    @Test func aMissingPasswordNeverReachesLogin() async throws {
        let host = "router-nopass.test"
        let router = try client(host, password: nil, Self.router { _, _, _, _ in Self.statusReply })
        await #expect(throws: GLiNetError.noPassword) { try await router.status() }
        #expect(FakeRouter.calls(host: host) == [])
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
        for host in ["", "bad host", "a/b", "-flag", "192.168.8.1:80", "a:b"] {
            #expect(throws: GLiNetError.invalidHost) { try GLiNetClient(host: host, password: { nil }) }
        }
        for timeout in [TimeInterval.infinity, .nan, 0] {
            #expect(throws: GLiNetError.invalidHost) { try GLiNetClient(host: "192.168.8.1", password: { nil }, timeout: timeout) }
        }
    }
}
