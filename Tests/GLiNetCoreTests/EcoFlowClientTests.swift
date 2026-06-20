import Foundation
import XCTest
@testable import GLiNetCore

final class EcoFlowClientTests: XCTestCase {
    func testDecodesStatusAndOutputsUsingDocumentedRiver3PlusShape() async throws {
        let transport = StubEcoFlowHTTPTransport(responses: [
            "/v1/status": .success("""
            {
              "battery": { "percent": 83, "state": "discharging" },
              "power": { "inputWatts": 0, "outputWatts": 27, "netWatts": -27 },
              "outputs": {
                "ac": { "state": "off", "watts": 0 },
                "dc": { "state": "off", "watts": 0 },
                "usb": { "state": "off", "watts": 0 }
              },
              "updatedAt": "2026-06-19T17:03:10.960Z"
            }
            """),
            "/v1/outputs": .success("""
            {
              "outputs": {
                "ac": { "state": "off", "watts": 0, "controllable": "supported" },
                "dc": { "state": "off", "watts": 0, "controllable": "supported" },
                "usb": { "state": "off", "watts": 0, "controllable": "unknown" }
              },
              "updatedAt": "2026-06-19T17:03:10.960Z"
            }
            """)
        ])
        let client = EcoFlowHTTPClient(baseURL: URL(string: "http://router.local:8787")!, transport: transport)

        let status = try await client.status()
        let outputs = try await client.outputs()

        XCTAssertEqual(status.battery.percent, 83)
        XCTAssertEqual(status.battery.state, .discharging)
        XCTAssertEqual(status.power.inputWatts, 0)
        XCTAssertEqual(status.power.outputWatts, 27)
        XCTAssertEqual(status.power.netWatts, -27)
        XCTAssertEqual(status.outputs.ac.state, .off)
        XCTAssertEqual(outputs.outputs.ac.controllable, .supported)
        XCTAssertEqual(outputs.outputs.usb.controllable, .unknown)
    }

    func testPostsOutputControlAndPreservesUnknownResult() async throws {
        let transport = StubEcoFlowHTTPTransport(responses: [
            "/v1/outputs/ac": .success("""
            {
              "target": "ac",
              "requestedState": "off",
              "result": "unknown",
              "observedState": "unknown",
              "message": "Command was published to EcoFlow cloud MQTT; confirmation decoding is not implemented yet."
            }
            """)
        ])
        let client = EcoFlowHTTPClient(baseURL: URL(string: "http://router.local:8787")!, transport: transport)

        let response = try await client.setOutput(.ac, state: .off)

        XCTAssertEqual(transport.requests.map(\.method), ["POST"])
        XCTAssertEqual(transport.requests[0].path, "/v1/outputs/ac")
        XCTAssertEqual(transport.requests[0].body, #"{"state":"off"}"#)
        XCTAssertEqual(response.target, .ac)
        XCTAssertEqual(response.result, .unknown)
        XCTAssertEqual(response.observedState, .unknown)
    }

    func testThrowsStableAPIErrorEnvelope() async {
        let transport = StubEcoFlowHTTPTransport(responses: [
            "/v1/status": .failure(statusCode: 500, body: """
            {
              "error": {
                "code": "internal_error",
                "message": "Internal server error.",
                "details": {}
              }
            }
            """)
        ])
        let client = EcoFlowHTTPClient(baseURL: URL(string: "http://router.local:8787")!, transport: transport)

        do {
            _ = try await client.status()
            XCTFail("Expected EcoFlow API error.")
        } catch let error as EcoFlowClientError {
            XCTAssertEqual(error.localizedDescription, "EcoFlow API error internal_error: Internal server error.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class StubEcoFlowHTTPTransport: EcoFlowHTTPTransport, @unchecked Sendable {
    enum Response {
        case success(String)
        case failure(statusCode: Int, body: String)
    }

    struct Request: Equatable {
        var method: String
        var path: String
        var body: String?
    }

    private let responses: [String: Response]
    private(set) var requests: [Request] = []

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> EcoFlowHTTPResponse {
        let path = request.url?.path ?? ""
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        requests.append(Request(method: request.httpMethod ?? "GET", path: path, body: body))
        switch responses[path] {
        case .success(let body):
            return EcoFlowHTTPResponse(statusCode: 200, data: Data(body.utf8))
        case .failure(let statusCode, let body):
            return EcoFlowHTTPResponse(statusCode: statusCode, data: Data(body.utf8))
        case .none:
            return EcoFlowHTTPResponse(statusCode: 404, data: Data())
        }
    }
}
