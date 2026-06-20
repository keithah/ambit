import Foundation

public struct EcoFlowHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol EcoFlowHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> EcoFlowHTTPResponse
}

public struct URLSessionEcoFlowHTTPTransport: EcoFlowHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> EcoFlowHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return EcoFlowHTTPResponse(statusCode: statusCode, data: data)
    }
}

public protocol EcoFlowClientProtocol: Sendable {
    func device() async throws -> EcoFlowDeviceInfo
    func status() async throws -> EcoFlowDeviceStatus
    func stats() async throws -> EcoFlowDeviceStats
    func outputs() async throws -> EcoFlowOutputsSnapshot
    func setOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async throws -> EcoFlowControlResponse
    func diagnostics() async throws -> EcoFlowDiagnosticsSnapshot
}

public enum EcoFlowClientError: Error, LocalizedError, Equatable, Sendable {
    case api(code: String, message: String)
    case invalidBaseURL
    case invalidControlState
    case invalidResponse(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .api(let code, let message):
            return "EcoFlow API error \(code): \(message)"
        case .invalidBaseURL:
            return "EcoFlow API base URL is invalid."
        case .invalidControlState:
            return "EcoFlow output controls require on or off state."
        case .invalidResponse(let statusCode):
            return "EcoFlow API returned HTTP \(statusCode)."
        }
    }
}

public struct EcoFlowHTTPClient: EcoFlowClientProtocol {
    private let baseURL: URL
    private let transport: EcoFlowHTTPTransport
    private let decoder = JSONDecoder()

    public init(baseURL: URL, transport: EcoFlowHTTPTransport = URLSessionEcoFlowHTTPTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func device() async throws -> EcoFlowDeviceInfo {
        try await get("/v1/device")
    }

    public func status() async throws -> EcoFlowDeviceStatus {
        try await get("/v1/status")
    }

    public func stats() async throws -> EcoFlowDeviceStats {
        try await get("/v1/stats")
    }

    public func outputs() async throws -> EcoFlowOutputsSnapshot {
        try await get("/v1/outputs")
    }

    public func setOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async throws -> EcoFlowControlResponse {
        guard state == .on || state == .off else {
            throw EcoFlowClientError.invalidControlState
        }
        let body = #"{"state":"\#(state.rawValue)"}"#
        return try await send(path: "/v1/outputs/\(target.rawValue)", method: "POST", body: Data(body.utf8))
    }

    public func diagnostics() async throws -> EcoFlowDiagnosticsSnapshot {
        try await get("/v1/diagnostics")
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(path: path, method: "GET", body: nil)
    }

    private func send<Response: Decodable>(path: String, method: String, body: Data?) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw EcoFlowClientError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let response = try await transport.send(request)
        if (200..<300).contains(response.statusCode) {
            return try decoder.decode(Response.self, from: response.data)
        }

        if let error = try? decoder.decode(EcoFlowAPIErrorBody.self, from: response.data).error {
            throw EcoFlowClientError.api(code: error.code, message: error.message)
        }
        throw EcoFlowClientError.invalidResponse(statusCode: response.statusCode)
    }
}
