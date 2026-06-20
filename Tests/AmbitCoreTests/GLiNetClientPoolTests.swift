import Foundation
import XCTest
@testable import AmbitCore

final class GLiNetClientPoolTests: XCTestCase {
    func testReturnsSameClientForSameEndpointAndUsername() async throws {
        let pool = GLiNetClientPool()
        let endpoint = URL(string: "http://192.168.8.1/rpc")!

        let first = await pool.client(endpoint: endpoint, username: "root", passwordProvider: { "secret" })
        let second = await pool.client(endpoint: endpoint, username: "root", passwordProvider: { "secret" })

        XCTAssertTrue(first === second)
    }

    func testReturnsDifferentClientForDifferentEndpoint() async throws {
        let pool = GLiNetClientPool()

        let first = await pool.client(endpoint: URL(string: "http://192.168.8.1/rpc")!, username: "root", passwordProvider: { "secret" })
        let second = await pool.client(endpoint: URL(string: "http://router.example.com/rpc")!, username: "root", passwordProvider: { "secret" })

        XCTAssertFalse(first === second)
    }
}
