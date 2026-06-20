import XCTest
@testable import AmbitCore

final class JSONRPCTests: XCTestCase {
    func testAuthenticatedCallEnvelopeEncodesSessionServiceMethodAndArgs() throws {
        let request = JSONRPCRequest.call(
            id: 42,
            sid: "sid-123",
            service: "system",
            method: "get_status",
            args: ["detail": .bool(true)]
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 42)
        XCTAssertEqual(object["method"] as? String, "call")
        let params = try XCTUnwrap(object["params"] as? [Any])
        XCTAssertEqual(params[0] as? String, "sid-123")
        XCTAssertEqual(params[1] as? String, "system")
        XCTAssertEqual(params[2] as? String, "get_status")
        XCTAssertEqual((params[3] as? [String: Any])?["detail"] as? Bool, true)
    }

    func testResponseDecodingThrowsJSONRPCError() throws {
        let data = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Access denied"}}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(JSONRPCResponse<JSONObject>.self, from: data).value()) { error in
            guard case JSONRPCClientError.rpc(let rpcError) = error else {
                return XCTFail("Expected RPC error, got \(error)")
            }
            XCTAssertEqual(rpcError.code, -32000)
            XCTAssertEqual(rpcError.message, "Access denied")
        }
    }
}
