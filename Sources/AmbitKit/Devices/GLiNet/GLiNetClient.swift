import CryptoKit
import Foundation
import Network

/// Talks to a GL.iNet router's JSON-RPC endpoint (`/rpc`, firmware 4.x) on the local network.
/// Logs in with a challenge and a hash, so the password itself is never sent.
/// Not yet verified against a physical router: see docs/decisions.md.
public actor GLiNetClient {
    private let endpoint: URL
    private let username: String
    private let password: @Sendable () -> String?
    private let session: URLSession
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var sessionID: String?
    private var nextID = 1

    // The router locks its admin login after a few failures, and this client is polled every few
    // seconds. So a failed login is remembered and not repeated until something has changed.
    private var loginInFlight: Task<String, Error>?
    private var rejectedPassword: SHA256Digest?
    private var lastPassword: SHA256Digest?
    private var lockedUntil: Date?
    private var loginBackoff: (until: Date, error: any Error)?
    private var deniedCalls: [String: Date] = [:]

    /// When the router reports a lockout without saying for how long.
    static let defaultLockout: TimeInterval = 300
    /// How long a login that failed for an unknown reason is left alone.
    static let loginRetryDelay: TimeInterval = 60
    /// How long a call the router refuses is left alone.
    static let deniedCallDelay: TimeInterval = 300

    /// `password` is asked for at each login, so it can come straight from the Keychain.
    /// `timeout` bounds each request as a whole.
    public init(
        host: String,
        username: String = "root",
        password: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        timeout: TimeInterval = 4,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard ProbeTarget.isValidHost(host), timeout.isFinite, timeout > 0 else { throw GLiNetError.invalidHost }
        // A colon is valid only inside an IPv6 address, which a URL writes in brackets.
        var literal = host
        if host.contains(":") {
            guard IPv6Address(host) != nil else { throw GLiNetError.invalidHost }
            literal = "[\(host)]"
        }
        guard let url = URL(string: "http://\(literal)/rpc"), url.host != nil else { throw GLiNetError.invalidHost }
        self.endpoint = url
        self.username = username
        self.password = password
        self.session = session
        self.timeout = timeout
        self.now = now
    }

    public func status() async throws -> GLiNetStatus {
        GLiNetStatus(systemStatus: try await call("system", "get_status"))
    }

    /// nil when the router has no VPN client tunnel, or its firmware has no `vpn-client` service.
    public func vpn() async throws -> GLiNetVPN? {
        do {
            return GLiNetVPN(vpnClientStatus: try await call("vpn-client", "get_status"))
        } catch GLiNetError.rpc(code: Self.methodNotFound, _) {
            return nil
        }
    }

    public func setVPN(on: Bool) async throws {
        guard let tunnel = try await vpn() else { throw GLiNetError.noVPN }
        _ = try await call("vpn-client", "set_tunnel", ["tunnel_id": tunnel.tunnelID, "enabled": on])
    }

    // MARK: Calls

    private static let accessDenied = -32000
    private static let methodNotFound = -32601
    private static let loginLocked = -32003

    private func call(_ service: String, _ method: String, _ arguments: [String: any Sendable] = [:]) async throws -> [String: Any] {
        let name = "\(service).\(method)"
        if let until = deniedCalls[name] {
            guard until <= now() else { throw GLiNetError.accessDenied }
            deniedCalls[name] = nil
        }
        let used = try await login()
        do {
            return try await send("call", [used, service, method, arguments])
        } catch GLiNetError.rpc(code: Self.accessDenied, _) {
            // Most likely the session expired (router restart, idle timeout): log in once more
            // and retry. Another call may already have replaced the session; keep that one.
            if sessionID == used { sessionID = nil }
            let fresh = try await login()
            do {
                return try await send("call", [fresh, service, method, arguments])
            } catch GLiNetError.rpc(code: Self.accessDenied, _) {
                // Denied with a brand-new session: the router refuses this call itself. Asking
                // again would open a new session on every poll, so leave it alone for a while.
                // If the session was replaced meanwhile, this answer says nothing about the new one.
                if sessionID == fresh { deniedCalls[name] = now().addingTimeInterval(Self.deniedCallDelay) }
                throw GLiNetError.accessDenied
            }
        }
    }

    /// Returns the session, logging in if there is none. Calls that arrive while a login is
    /// under way share it instead of starting their own.
    private func login() async throws -> String {
        if let sessionID { return sessionID }
        if let loginInFlight { return try await loginInFlight.value }
        let task = Task { try await performLogin() }
        loginInFlight = task
        defer { loginInFlight = nil }
        return try await task.value
    }

    private func performLogin() async throws -> String {
        guard let password = password(), !password.isEmpty else { throw GLiNetError.noPassword }
        let digest = SHA256.hash(data: Data(password.utf8))
        if digest != lastPassword {
            // A new password is a new situation: forget what the old one was refused.
            lastPassword = digest
            loginBackoff = nil
            deniedCalls = [:]
        }
        guard digest != rejectedPassword else { throw GLiNetError.wrongPassword }
        if let lockedUntil {
            let remaining = lockedUntil.timeIntervalSince(now())
            guard remaining <= 0 else { throw GLiNetError.lockedOut(seconds: Int(remaining.rounded(.up))) }
            self.lockedUntil = nil
        }
        if let loginBackoff {
            guard loginBackoff.until <= now() else { throw loginBackoff.error }
            self.loginBackoff = nil
        }
        // A failed challenge costs nothing on the router, so it is simply reported.
        let challenge = try await send("challenge", ["username": username])
        guard let algorithm = (challenge["alg"] as? NSNumber)?.intValue,
              let scheme = UnixCrypt.Scheme(rawValue: algorithm),
              let salt = challenge["salt"] as? String,
              let nonce = challenge["nonce"] as? String else { throw GLiNetError.unexpectedResponse }
        let hash: String
        do {
            hash = try Self.loginHash(
                username: username, password: password, scheme: scheme, salt: salt, nonce: nonce,
                method: challenge["hash-method"] as? String
            )
        } catch GLiNetError.wrongPassword {
            rejectedPassword = digest
            throw GLiNetError.wrongPassword
        }
        // From here the router may count a failed attempt, so no failure is retried at once.
        do {
            let reply = try await send("login", ["username": username, "hash": hash])
            guard let sid = reply["sid"] as? String, !sid.isEmpty else { throw GLiNetError.unexpectedResponse }
            sessionID = sid
            rejectedPassword = nil
            return sid
        } catch GLiNetError.rpc(code: Self.accessDenied, _) {
            rejectedPassword = digest
            throw GLiNetError.wrongPassword
        } catch GLiNetError.lockedOut(let seconds) {
            let wait = seconds.flatMap { $0 > 0 ? TimeInterval($0) : nil } ?? Self.defaultLockout
            lockedUntil = now().addingTimeInterval(wait)
            throw GLiNetError.lockedOut(seconds: seconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            loginBackoff = (now().addingTimeInterval(Self.loginRetryDelay), error)
            throw error
        }
    }

    /// `hash(username:crypt(password, salt):nonce)`, hex. The router names the outer hash in
    /// `hash-method`; older firmware omits it and expects MD5.
    static func loginHash(username: String, password: String, scheme: UnixCrypt.Scheme, salt: String, nonce: String, method: String?) throws -> String {
        let crypted: String
        do {
            crypted = try UnixCrypt.hash(password: password, salt: salt, scheme: scheme)
        } catch is UnixCrypt.PasswordTooLong {
            // No router accepts a password this long, so it cannot be the right one.
            throw GLiNetError.wrongPassword
        } catch {
            throw GLiNetError.unexpectedResponse
        }
        let input = Data("\(username):\(crypted):\(nonce)".utf8)
        let digest: [UInt8]
        switch method?.lowercased() {
        case nil, "", "md5": digest = Array(Insecure.MD5.hash(data: input))
        case "sha256": digest = Array(SHA256.hash(data: input))
        case "sha512": digest = Array(SHA512.hash(data: input))
        default: throw GLiNetError.unexpectedResponse
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func send(_ method: String, _ params: Any) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let (body, response) = try await Self.data(for: request, session: session, timeout: timeout)
        guard let http = response as? HTTPURLResponse else { throw GLiNetError.unexpectedResponse }
        guard http.statusCode == 200 else { throw GLiNetError.http(http.statusCode) }
        guard let reply = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw GLiNetError.unexpectedResponse
        }
        if let error = reply["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            if code == Self.loginLocked {
                throw GLiNetError.lockedOut(seconds: ((error["data"] as? [String: Any])?["wait"] as? NSNumber)?.intValue)
            }
            throw GLiNetError.rpc(code: code, message: error["message"] as? String ?? "")
        }
        guard let result = reply["result"] else { throw GLiNetError.unexpectedResponse }
        // Commands may answer with an empty or non-object result.
        return result as? [String: Any] ?? [:]
    }

    private static func data(for request: URLRequest, session: URLSession, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                do {
                    return try await session.data(for: request)
                } catch let error as URLError where error.code == .timedOut {
                    // URLSession's own idle timeout may fire first; report one timeout error.
                    throw GLiNetError.timedOut
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GLiNetError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw GLiNetError.unexpectedResponse }
            return first
        }
    }
}
