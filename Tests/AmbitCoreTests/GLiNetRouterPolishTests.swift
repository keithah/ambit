import XCTest
@testable import AmbitCore

final class GLiNetRouterPolishTests: XCTestCase {
    func testRouterStatusParsesClientCountFromGetStatusPayload() {
        let payload: JSONObject = [
            "client": .array([.object(["cable_total": .number(2), "wireless_total": .number(5)])])
        ]
        XCTAssertEqual(RouterStatus(payload: payload).clientCount, 7)
    }

    func testRouterStatusClientCountIsNilWhenAbsent() {
        XCTAssertNil(RouterStatus(payload: [:]).clientCount)
    }

    func testRouterSnapshotEmitsClientHostnameAndModelMetrics() {
        let status = RouterStatus(reachable: true, hostname: "GL-X3000", model: "GL.iNet GL-X3000", clientCount: 7)
        let snapshot = ProviderSnapshot.router(status)

        XCTAssertEqual(snapshot.metric("clients")?.value, .level(7))
        XCTAssertEqual(snapshot.metric("clients")?.deviceClass, .count)
        XCTAssertEqual(snapshot.metric("hostname")?.value, .text("GL-X3000"))
        XCTAssertEqual(snapshot.metric("hostname")?.category, .diagnostic)
        XCTAssertEqual(snapshot.metric("device_model")?.value, .text("GL.iNet GL-X3000"))
    }

    func testRouterProviderFoldsBoardInfoIntoStatus() async {
        let client = BoardStubClient(
            routerStatus: RouterStatus(reachable: true, clientCount: 3), // hostname/model absent (as get_status really is)
            board: RouterBoardInfo(hostname: "GL-X3000", model: "GL.iNet GL-X3000")
        )
        let provider = GLiNetRouterProvider(
            clientFactory: { _, _, _ in client },
            passwordProvider: { "secret" }
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: "router.local", settings: AppSettings(username: "root")))

        XCTAssertEqual(snapshot.metric("hostname")?.value, .text("GL-X3000"))
        XCTAssertEqual(snapshot.metric("device_model")?.value, .text("GL.iNet GL-X3000"))
        XCTAssertEqual(snapshot.metric("clients")?.value, .level(3))
    }

    func testRouterProviderSurvivesBoardInfoFailure() async {
        let client = BoardStubClient(
            routerStatus: RouterStatus(reachable: true, hostname: "fallback-host", clientCount: 1),
            board: nil // throws
        )
        let provider = GLiNetRouterProvider(
            clientFactory: { _, _, _ in client },
            passwordProvider: { "secret" }
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: "router.local", settings: AppSettings(username: "root")))

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metric("hostname")?.value, .text("fallback-host"))
    }

    func testRouterDescriptorsIncludeClientsHostnameModel() {
        let descriptors = GLiNetRouterProvider().entityDescriptors()
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id.rawValue, $0) })

        XCTAssertEqual(byID["glinet/router.clients"]?.deviceClass, .count)
        XCTAssertEqual(byID["glinet/router.clients"]?.capability, ProviderCapability(rawValue: "clients"))
        XCTAssertEqual(byID["glinet/router.hostname"]?.kind, .text)
        XCTAssertEqual(byID["glinet/router.hostname"]?.category, .diagnostic)
        XCTAssertEqual(byID["glinet/router.device_model"]?.kind, .text)
    }
}

private struct BoardStubClient: GLiNetClientProtocol, @unchecked Sendable {
    let routerStatusResult: RouterStatus
    let board: RouterBoardInfo?

    init(routerStatus: RouterStatus, board: RouterBoardInfo?) {
        self.routerStatusResult = routerStatus
        self.board = board
    }

    func call(service: String, method: String, args: JSONObject) async throws -> JSONObject { [:] }
    func routerStatus() async throws -> RouterStatus { routerStatusResult }
    func vpnStatus() async throws -> VPNStatus { VPNStatus(protocol: .wireGuard, isConnected: false) }
    func setVPNEnabled(_ enabled: Bool, protocol vpnProtocol: VPNProtocol) async throws {}

    func boardInfo() async throws -> RouterBoardInfo {
        guard let board else { throw JSONRPCClientError.commandFailed("no board") }
        return board
    }
}
