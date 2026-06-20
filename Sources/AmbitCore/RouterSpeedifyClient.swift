import Foundation

public protocol RouterSpeedifySocket: Sendable {
    func send(event: String, payload: JSONObject) async throws
    func receive() async throws -> String
    func close() async
}

public protocol RouterSpeedifySocketFactory: Sendable {
    func makeSocket(url: URL) async throws -> RouterSpeedifySocket
}

public protocol RouterSpeedifyClientProtocol: Sendable {
    func status(host: String) async throws -> SpeedifyStatus
    func connect(host: String, server: String) async throws
    func disconnect(host: String) async throws
    func setBondingMode(_ mode: SpeedifyBondingMode, host: String) async throws
    func setNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String, host: String) async throws
}

public extension RouterSpeedifyClientProtocol {
    func connect(host: String) async throws {
        try await connect(host: host, server: "auto")
    }
}

public struct URLSessionRouterSpeedifySocketFactory: RouterSpeedifySocketFactory {
    public init() {}

    public func makeSocket(url: URL) async throws -> RouterSpeedifySocket {
        URLSessionRouterSpeedifySocket(url: url)
    }
}

public final class URLSessionRouterSpeedifySocket: RouterSpeedifySocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        self.task = session.webSocketTask(with: url, protocols: ["event-protocol"])
        self.task.resume()
    }

    public func send(event: String, payload: JSONObject) async throws {
        let message = JSONValue.array([
            .string(event),
            .object(payload),
            .string("speedify_ui")
        ])
        let data = try JSONEncoder().encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONRPCClientError.commandFailed("Could not encode Speedify websocket message.")
        }
        try await task.send(.string(string))
    }

    public func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let string):
            return string
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    public func close() async {
        task.cancel(with: .goingAway, reason: nil)
    }
}

public struct RouterSpeedifyClient: RouterSpeedifyClientProtocol, Sendable {
    private let socketFactory: RouterSpeedifySocketFactory
    private let timeout: TimeInterval

    public init(socketFactory: RouterSpeedifySocketFactory = URLSessionRouterSpeedifySocketFactory(), timeout: TimeInterval = 3) {
        self.socketFactory = socketFactory
        self.timeout = timeout
    }

    public func status(host: String) async throws -> SpeedifyStatus {
        let socket = try await openSocket(host: host)
        defer { Task { await socket.close() } }

        for event in Self.statusRequestEvents {
            try await socket.send(event: event, payload: [:])
        }

        var builder = RouterSpeedifyStatusBuilder()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let message = try await receive(socket: socket, timeout: max(0.01, deadline.timeIntervalSinceNow)) else {
                break
            }
            guard let event = Self.decodeEvent(message) else { continue }
            builder.apply(event: event.name, payload: event.payload)
        }

        return builder.status()
    }

    public func networkPayloads(host: String) async throws -> [JSONObject] {
        let socket = try await openSocket(host: host)
        defer { Task { await socket.close() } }

        try await socket.send(event: "request_networks", payload: [:])

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let message = try await receive(socket: socket, timeout: max(0.01, deadline.timeIntervalSinceNow)) else {
                break
            }
            guard let event = Self.decodeEvent(message), event.name == "report_networks" else { continue }
            return event.payload.arrayValue?.compactMap(\.objectValue) ?? []
        }

        return []
    }


    public func connect(host: String, server: String = "auto") async throws {
        try await send(host: host, event: "server_auto_connect", payload: ["server": .string(server)])
    }

    public func disconnect(host: String) async throws {
        try await send(host: host, event: "server_disconnect", payload: [:])
    }

    public func setBondingMode(_ mode: SpeedifyBondingMode, host: String) async throws {
        guard !mode.commandCode.isEmpty else {
            throw JSONRPCClientError.commandFailed("Cannot set an unknown Speedify bonding mode.")
        }
        try await send(host: host, event: "set_connection_algorithm", payload: ["algorithm": .string(mode.commandCode)])
    }

    public func setNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String, host: String) async throws {
        try await send(host: host, event: "set_network_priority", payload: [
            "network": .string(networkID),
            "priority": .number(Double(priority.rawValue))
        ])
    }

    private func send(host: String, event: String, payload: JSONObject) async throws {
        let socket = try await openSocket(host: host)
        defer { Task { await socket.close() } }
        try await socket.send(event: event, payload: payload)
    }

    private func openSocket(host: String) async throws -> RouterSpeedifySocket {
        guard let url = URL.routerSpeedifyWebSocket(host: host) else {
            throw JSONRPCClientError.commandFailed("Invalid Speedify websocket endpoint.")
        }
        return try await socketFactory.makeSocket(url: url)
    }

    private func receive(socket: RouterSpeedifySocket, timeout: TimeInterval) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await socket.close()
                return nil
            }
            let value = try await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    private static let statusRequestEvents = [
        "request_current_state",
        "request_connected_server",
        "request_connection_settings",
        "request_server_settings",
        "request_networks",
        "request_session_stats",
        "request_directory"
    ]

    private static func decodeEvent(_ message: String) -> (name: String, payload: JSONValue)? {
        guard let data = message.data(using: .utf8),
              let array = try? JSONDecoder().decode(JSONValue.self, from: data).arrayValue,
              let name = array.first?.stringValue
        else { return nil }
        return (name, array.dropFirst().first ?? .null)
    }
}

private struct RouterSpeedifyStatusBuilder {
    private var stateCode: Int?
    private var connectedServer: JSONObject?
    private var connectionSettings: JSONObject?
    private var networkPayloads: [JSONObject] = []
    private var connectionStatsByNetwork: [String: JSONObject] = [:]
    private var graphSamples: [SpeedifyGraphSample] = []
    private var sessionDownloadBytes: Int?
    private var sessionUploadBytes: Int?

    mutating func apply(event: String, payload: JSONValue) {
        switch event {
        case "report_current_state":
            stateCode = payload.objectValue?["state"]?.intValue ?? payload.intValue
        case "report_connected_server":
            connectedServer = payload.objectValue
        case "report_connection_settings":
            connectionSettings = payload.objectValue
        case "report_networks":
            networkPayloads = payload.arrayValue?.compactMap(\.objectValue) ?? []
        case "report_connection_stats":
            let connections = payload.objectValue?["connections"]?.arrayValue?.compactMap(\.objectValue) ?? []
            connectionStatsByNetwork = connections.reduce(into: [:]) { partial, connection in
                guard let id = connection.firstString(keys: ["guid"]), id != "speedify" else { return }
                partial[id] = connection
            }
            if let speedify = connections.first(where: { $0.firstString(keys: ["guid"]) == "speedify" }) {
                graphSamples.append(SpeedifyGraphSample(
                    timestamp: payload.objectValue?["time"]?.intValue.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                    totalBps: speedify.firstInt(keys: ["totBps"]) ?? ((speedify.firstInt(keys: ["rcvBps"]) ?? 0) + (speedify.firstInt(keys: ["sndBps"]) ?? 0)),
                    downloadBps: speedify.firstInt(keys: ["rcvBps"]),
                    uploadBps: speedify.firstInt(keys: ["sndBps"])
                ))
            }
        case "report_session_stats":
            let current = payload.objectValue?["0"]?.objectValue
            sessionDownloadBytes = current?.firstInt(keys: ["bytes_recv"])
            sessionUploadBytes = current?.firstInt(keys: ["bytes_sent"])
        default:
            break
        }
    }

    func status() -> SpeedifyStatus {
        SpeedifyStatus(
            isInstalled: true,
            isAvailable: true,
            isConnected: stateCode == 6,
            state: stateLabel(stateCode),
            server: serverLabel(connectedServer),
            bondingMode: connectionSettings?["algorithm"]?.stringValue.map(SpeedifyBondingMode.init(code:)),
            networks: networkPayloads.map { Self.network($0, stats: connectionStatsByNetwork[$0.firstString(keys: ["guid", "id", "key"]) ?? ""]) },
            secondaryThresholdMbps: connectionSettings?.firstInt(keys: ["connection_secondary_speed_activation", "overflow_threshold", "priority_overflow_threshold", "connection_priority_overflow_treshold"]),
            startupConnect: connectionSettings?["startup_connect"]?.boolValue,
            sessionDownloadBytes: sessionDownloadBytes,
            sessionUploadBytes: sessionUploadBytes,
            graphSamples: graphSamples
        )
    }

    private func stateLabel(_ code: Int?) -> String {
        switch code {
        case 0: return "Logged out"
        case 1: return "Logging in"
        case 2: return "Disconnected"
        case 3: return "Auto connecting"
        case 4: return "Connecting"
        case 5: return "Disconnecting"
        case 6: return "Connected"
        case 7: return "Over limit"
        default: return "Unknown"
        }
    }

    private func serverLabel(_ payload: JSONObject?) -> String? {
        guard let payload else { return nil }
        if let longName = payload.firstString(keys: ["longName"]), !longName.isEmpty {
            return longName.replacingOccurrences(of: "USA", with: "United States")
        }
        let country = payload.firstString(keys: ["country", "countryName"])
        let city = payload.firstString(keys: ["city", "cityName"])
        let server = payload.firstString(keys: ["server", "name", "displayName"])
        let location = [country, city].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " - ")
        if location.isEmpty {
            return server
        }
        if let server, !server.isEmpty {
            return "\(location) \(server)"
        }
        return location
    }

    private static func network(_ payload: JSONObject, stats: JSONObject?) -> SpeedifyNetwork {
        let id = payload.firstString(keys: ["guid", "id", "key"]) ?? UUID().uuidString
        let name = payload.firstString(keys: ["name", "description", "interface"]) ?? id
        return SpeedifyNetwork(
            id: id,
            name: name,
            type: payload.firstString(keys: ["type"]),
            isp: payload.firstString(keys: ["isp"]),
            priority: SpeedifyNetworkPriority(value: payload.firstInt(keys: ["priority", "workingPriority"]) ?? -1),
            receiveBps: stats?.firstInt(keys: ["rcvBps", "receiveBps", "rxBps"]) ?? payload.firstInt(keys: ["rcvBps", "receiveBps", "rxBps"]),
            sendBps: stats?.firstInt(keys: ["sndBps", "sendBps", "txBps"]) ?? payload.firstInt(keys: ["sndBps", "sendBps", "txBps"]),
            statusMessage: payload.firstString(keys: ["status", "statusMessage", "message", "error"]),
            isConnected: Self.isConnected(payload)
        )
    }

    private static func isConnected(_ payload: JSONObject) -> Bool {
        if payload.firstBool(keys: ["offline"]) == true { return false }
        if let state = payload.firstInt(keys: ["connectionState"]) { return state != 0 }
        return true
    }
}

public extension URL {
    static func routerSpeedifyWebSocket(host: String) -> URL? {
        let endpoint = "/luci-app-speedify/api/ws"
        if var components = URLComponents(string: host), components.scheme != nil {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            components.path = endpoint
            components.query = nil
            components.fragment = nil
            return components.url
        }
        return URL(string: "ws://\(host)\(endpoint)")
    }
}
