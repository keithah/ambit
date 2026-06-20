import XCTest
@testable import GLiNetCore

final class RouterErrorTests: XCTestCase {
    func testLoginLimitErrorExposesRetryWaitSeconds() {
        let error = JSONRPCError(
            code: -32003,
            message: "Login fail number over limit",
            data: .object(["wait": .number(587)])
        )

        XCTAssertEqual(error.retryAfterSeconds, 587)
        XCTAssertTrue(JSONRPCClientError.rpc(error).isLoginRateLimited)
        XCTAssertEqual(
            JSONRPCClientError.rpc(error).errorDescription,
            "Router login is locked for 9m 47s."
        )
    }
}
