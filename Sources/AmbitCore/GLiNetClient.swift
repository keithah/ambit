import Foundation

public protocol RouterTransport: Sendable {
    func send(_ request: JSONRPCRequest, to endpoint: URL) async throws -> Data
}

public struct URLSessionRouterTransport: RouterTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: JSONRPCRequest, to endpoint: URL) async throws -> Data {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JSONRPCClientError.commandFailed("HTTP \(http.statusCode) from router.")
        }
        return data
    }
}

public protocol GLiNetClientProtocol: Sendable {
    func call(service: String, method: String, args: JSONObject) async throws -> JSONObject
    func routerStatus() async throws -> RouterStatus
    func vpnStatus() async throws -> VPNStatus
    func setVPNEnabled(_ enabled: Bool, protocol vpnProtocol: VPNProtocol) async throws
}

public extension GLiNetClientProtocol {
    func call(service: String, method: String) async throws -> JSONObject {
        try await call(service: service, method: method, args: [:])
    }
}

public actor GLiNetClient: GLiNetClientProtocol {
    private let endpoint: URL
    private let username: String
    private let passwordProvider: @Sendable () throws -> String?
    private let transport: RouterTransport
    private var sid: String?
    private var nextID = 1

    public init(
        endpoint: URL,
        username: String,
        passwordProvider: @escaping @Sendable () throws -> String?,
        transport: RouterTransport = URLSessionRouterTransport()
    ) {
        self.endpoint = endpoint
        self.username = username
        self.passwordProvider = passwordProvider
        self.transport = transport
    }

    public func call(service: String, method: String, args: JSONObject = [:]) async throws -> JSONObject {
        do {
            return try await authenticatedCall(service: service, method: method, args: args)
        } catch JSONRPCClientError.rpc(let error) where isAuthError(error) {
            sid = nil
            return try await authenticatedCall(service: service, method: method, args: args)
        }
    }

    public func routerStatus() async throws -> RouterStatus {
        let status = try await call(service: "system", method: "get_status")
        return RouterStatus(payload: status)
    }

    public func vpnStatus() async throws -> VPNStatus {
        if let dashboard = try? await vpnClientDashboardStatus() {
            return dashboard
        }
        do {
            let wg = try await call(service: "wg-client", method: "get_status")
            return VPNStatus(protocol: .wireGuard, payload: wg)
        } catch let error as JSONRPCClientError where error.isMethodNotFound {
            do {
                let ovpn = try await call(service: "ovpn-client", method: "get_status")
                return VPNStatus(protocol: .openVPN, payload: ovpn)
            } catch let openVPNError as JSONRPCClientError where openVPNError.isMethodNotFound {
                return try await vpnServiceStatus()
            }
        }
    }

    private func vpnClientDashboardStatus() async throws -> VPNStatus {
        let status = try await call(service: "vpn-client", method: "get_status")
        let tunnels = try await call(service: "vpn-client", method: "get_tunnel")
        let configs = try await call(service: "vpn-client", method: "get_all_config_list")
        return VPNStatus.vpnClient(statusPayload: status, tunnelPayload: tunnels, configPayload: configs)
    }

    private func vpnServiceStatus() async throws -> VPNStatus {
        if let tailscale = try? await call(service: "tailscale", method: "get_status") {
            let status = VPNStatus.tailscale(payload: tailscale)
            if status.isConnected { return status }
        }
        if let tor = try? await call(service: "tor", method: "get_status") {
            let status = VPNStatus.tor(payload: tor)
            if status.isConnected { return status }
        }
        if let wgServer = try? await call(service: "wg-server", method: "get_status") {
            let status = VPNStatus.wireGuardServer(payload: wgServer)
            if status.isConnected { return status }
        }
        if let ovpnServer = try? await call(service: "ovpn-server", method: "get_status") {
            let status = VPNStatus.openVPNServer(payload: ovpnServer)
            if status.isConnected { return status }
            return status
        }
        return .unavailable("No supported VPN service API is active on this firmware.")
    }

    public func setVPNEnabled(_ enabled: Bool, protocol vpnProtocol: VPNProtocol = .wireGuard) async throws {
        if vpnProtocol == .vpnClient {
            let status = try await vpnClientDashboardStatus()
            guard let tunnelID = status.tunnelID, status.canToggle else {
                throw JSONRPCClientError.commandFailed(status.unavailableReason ?? "VPN client tunnel is not toggleable.")
            }
            _ = try await call(service: "vpn-client", method: "set_tunnel", args: [
                "tunnel_id": .number(Double(tunnelID)),
                "enabled": .bool(enabled)
            ])
            return
        }
        let service = vpnProtocol == .wireGuard ? "wg-client" : "ovpn-client"
        _ = try await call(service: service, method: enabled ? "start" : "stop")
    }

    private func authenticatedCall(service: String, method: String, args: JSONObject) async throws -> JSONObject {
        let activeSID = try await sessionID()
        let request = JSONRPCRequest.call(id: allocateID(), sid: activeSID, service: service, method: method, args: args)
        let data = try await transport.send(request, to: endpoint)
        return try JSONDecoder().decode(JSONRPCResponse<JSONObject>.self, from: data).value()
    }

    private func sessionID() async throws -> String {
        if let sid { return sid }
        let challengeRequest = JSONRPCRequest.challenge(id: allocateID(), username: username)
        let challengeData = try await transport.send(challengeRequest, to: endpoint)
        let challenge = try JSONDecoder().decode(JSONRPCResponse<JSONObject>.self, from: challengeData).value()
        guard
            let alg = challenge["alg"]?.intValue,
            let salt = challenge["salt"]?.stringValue,
            let nonce = challenge["nonce"]?.stringValue
        else {
            throw JSONRPCClientError.invalidChallenge
        }
        guard let password = try passwordProvider(), !password.isEmpty else {
            throw JSONRPCClientError.missingPassword
        }
        let hashMethod = challenge["hash-method"]?.stringValue
        let hash = try PasswordHasher.loginHash(username: username, password: password, alg: alg, salt: salt, nonce: nonce, hashMethod: hashMethod)
        let loginRequest = JSONRPCRequest.login(id: allocateID(), username: username, hash: hash)
        let loginData = try await transport.send(loginRequest, to: endpoint)
        let login = try JSONDecoder().decode(JSONRPCResponse<JSONObject>.self, from: loginData).value()
        guard let sid = login["sid"]?.stringValue else {
            throw JSONRPCClientError.invalidLogin
        }
        self.sid = sid
        return sid
    }

    private func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func isAuthError(_ error: JSONRPCError) -> Bool {
        error.code == -32000 || error.message.localizedCaseInsensitiveContains("access") || error.message.localizedCaseInsensitiveContains("session")
    }
}
