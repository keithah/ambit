import Foundation

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: JSONValue

    public init(id: Int, method: String, params: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public static func challenge(id: Int, username: String) -> JSONRPCRequest {
        JSONRPCRequest(id: id, method: "challenge", params: .object(["username": .string(username)]))
    }

    public static func login(id: Int, username: String, hash: String) -> JSONRPCRequest {
        JSONRPCRequest(id: id, method: "login", params: .object(["username": .string(username), "hash": .string(hash)]))
    }

    public static func call(id: Int, sid: String, service: String, method: String, args: JSONObject = [:]) -> JSONRPCRequest {
        JSONRPCRequest(id: id, method: "call", params: .array([
            .string(sid),
            .string(service),
            .string(method),
            .object(args)
        ]))
    }
}

public struct JSONRPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: Int?
    public let result: Result?
    public let error: JSONRPCError?

    public func value() throws -> Result {
        if let error {
            throw JSONRPCClientError.rpc(error)
        }
        guard let result else {
            throw JSONRPCClientError.missingResult
        }
        return result
    }
}

public struct JSONRPCError: Decodable, Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var retryAfterSeconds: Int? {
        guard code == -32003 else { return nil }
        return data?.objectValue?["wait"]?.intValue
    }
}

public enum JSONRPCClientError: Error, Equatable, LocalizedError, Sendable {
    case rpc(JSONRPCError)
    case missingResult
    case invalidChallenge
    case invalidLogin
    case missingPassword
    case unsupportedHashAlgorithm(Int)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rpc(let error):
            if let wait = error.retryAfterSeconds {
                return "Router login is locked for \(Self.formatDuration(wait))."
            }
            return "Router RPC error \(error.code): \(error.message)"
        case .missingResult:
            return "Router response did not include a result."
        case .invalidChallenge:
            return "Router challenge response was incomplete."
        case .invalidLogin:
            return "Router login response did not include a session id."
        case .missingPassword:
            return "Router password is not configured."
        case .unsupportedHashAlgorithm(let alg):
            return "Unsupported router password hash algorithm \(alg)."
        case .commandFailed(let message):
            return message
        }
    }

    public var isLoginRateLimited: Bool {
        if case .rpc(let error) = self {
            return error.code == -32003
        }
        return false
    }

    public var isMethodNotFound: Bool {
        if case .rpc(let error) = self {
            return error.code == -32601
        }
        return false
    }

    public var retryAfterSeconds: Int? {
        if case .rpc(let error) = self {
            return error.retryAfterSeconds
        }
        return nil
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 {
            return "\(remainder)s"
        }
        if remainder == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainder)s"
    }
}
