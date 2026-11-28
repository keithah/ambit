import CryptoKit
import Foundation
import Network

/// Stands in for a GL.iNet router, so the UI tests can show a router that answers. It listens on a
/// free port of this Mac only, and the app is told the port with `AMBIT_UI_TEST_ROUTER_PORT`.
///
/// It answers the calls Ambit makes (`challenge`, `login`, `system get_status`,
/// `vpn-client get_status` and `set_tunnel`) with replies shaped like firmware 4.x.
final class FakeRouter: @unchecked Sendable {
    static let password = "uitest-password"
    /// What the fake reports as its own address; the router page shows it.
    static let lanIP = "192.168.8.1"

    private static let salt = "abcdefgh"
    private static let nonce = "n0nce"
    /// `openssl passwd -1 -salt abcdefgh uitest-password`
    private static let crypted = "$1$abcdefgh$mma2I5tro/TTGrYMkgORh1"
    private static let session = "uitest-session"
    private static let accessDenied = -32000
    private static let methodNotFound = -32601

    private(set) var port = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeRouter")
    // Only touched on `queue`.
    private var vpnOn = true

    struct DidNotStart: Error {}

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw DidNotStart()
        }
        self.port = Int(port)
    }

    func stop() {
        listener.cancel()
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, received: Data())
    }

    /// Reads one request, answers it and closes the connection.
    private func read(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var received = received
            if let data { received.append(data) }
            if let body = Self.body(of: received) {
                let reply = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]).map(self.answer) ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(json)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, received: received)
            }
        }
    }

    /// The request's body, once all of it has arrived.
    private static func body(of request: Data) -> Data? {
        guard let headersEnd = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = String(decoding: request[..<headersEnd.lowerBound], as: UTF8.self)
        let length = headers.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = request[headersEnd.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    // MARK: JSON-RPC

    private func answer(_ request: [String: Any]) -> [String: Any] {
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": request["id"] ?? NSNull()]
        switch result(method: request["method"] as? String, params: request["params"]) {
        case .success(let result): reply["result"] = result
        case .failure(let refusal): reply["error"] = ["code": refusal.code, "message": refusal.message]
        }
        return reply
    }

    private struct Refusal: Error {
        var code: Int
        var message: String
    }

    private func result(method: String?, params: Any?) -> Result<[String: Any], Refusal> {
        switch method {
        case "challenge":
            // No `hash-method`: the login hash is then MD5, as on older firmware.
            return .success(["alg": 1, "salt": Self.salt, "nonce": Self.nonce])
        case "login":
            let expected = Insecure.MD5.hash(data: Data("root:\(Self.crypted):\(Self.nonce)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard (params as? [String: Any])?["hash"] as? String == expected else {
                return .failure(Refusal(code: Self.accessDenied, message: "Access denied"))
            }
            return .success(["sid": Self.session])
        case "call":
            guard let call = params as? [Any], call.count >= 3, call[0] as? String == Self.session,
                  let service = call[1] as? String, let name = call[2] as? String else {
                return .failure(Refusal(code: Self.accessDenied, message: "Access denied"))
            }
            return self.call("\(service).\(name)", call.count > 3 ? call[3] as? [String: Any] ?? [:] : [:])
        default:
            return .failure(Refusal(code: Self.methodNotFound, message: "Method not found"))
        }
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> Result<[String: Any], Refusal> {
        switch name {
        case "system.get_status":
            return .success([
                "network": [["interface": "wan", "up": true, "online": true]],
                "system": ["lan_ip": Self.lanIP, "uptime": 93_600],
                "client": [["cable_total": 1, "wireless_total": 2]],
            ])
        case "vpn-client.get_status":
            return .success(["status_list": [["tunnel_id": 1, "name": "Home", "enabled": vpnOn, "status": vpnOn ? 1 : 0]]])
        case "vpn-client.set_tunnel":
            vpnOn = arguments["enabled"] as? Bool ?? vpnOn
            return .success([:])
        default:
            return .failure(Refusal(code: Self.methodNotFound, message: "Method not found"))
        }
    }
}
