import Foundation
@testable import AmbitCore

final class MockRouterTransport: RouterTransport, @unchecked Sendable {
    enum Response: Sendable {
        case challenge(alg: Int, salt: String, nonce: String)
        case login(sid: String)
        case result(JSONObject)
        case rpcError(code: Int, message: String)
    }

    var responses: [Response] = []
    private(set) var calledMethods: [String] = []

    func send(_ request: JSONRPCRequest, to endpoint: URL) async throws -> Data {
        calledMethods.append(request.method)
        let response = responses.removeFirst()
        let object: [String: JSONValue]
        switch response {
        case .challenge(let alg, let salt, let nonce):
            object = [
                "jsonrpc": .string("2.0"),
                "id": .number(Double(request.id)),
                "result": .object(["alg": .number(Double(alg)), "salt": .string(salt), "nonce": .string(nonce)])
            ]
        case .login(let sid):
            object = [
                "jsonrpc": .string("2.0"),
                "id": .number(Double(request.id)),
                "result": .object(["sid": .string(sid)])
            ]
        case .result(let result):
            object = [
                "jsonrpc": .string("2.0"),
                "id": .number(Double(request.id)),
                "result": .object(result)
            ]
        case .rpcError(let code, let message):
            object = [
                "jsonrpc": .string("2.0"),
                "id": .number(Double(request.id)),
                "error": .object(["code": .number(Double(code)), "message": .string(message)])
            ]
        }
        return try JSONEncoder().encode(JSONValue.object(object))
    }
}

struct StubEndpointProber: EndpointProber {
    enum ProbeResult {
        case success(afterNanoseconds: UInt64)
        case failure(afterNanoseconds: UInt64)
    }

    let results: [String: ProbeResult]

    func challenge(host: String, username: String) async -> Bool {
        guard let result = results[host] else { return false }
        switch result {
        case .success(let delay):
            try? await Task.sleep(nanoseconds: delay)
            return true
        case .failure(let delay):
            try? await Task.sleep(nanoseconds: delay)
            return false
        }
    }
}

struct StubRouterAddressDiscovery: RouterAddressDiscovery {
    let defaultGateway: String?

    func defaultGatewayHost() async -> String? {
        defaultGateway
    }
}

struct StubProcessRunner: ProcessRunner {
    let results: [String: ProcessResult]

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let key = arguments.joined(separator: " ")
        return results[key] ?? ProcessResult(exitCode: 127, stdout: "", stderr: "not found")
    }
}
