import Foundation
import XCTest
@testable import AmbitCore

final class RouterSpeedifyClientTests: XCTestCase {
    func testStatusRequestsRouterSpeedifyStateAndParsesReports() async throws {
        let socket = StubSpeedifySocket(incoming: [
            event("report_current_state", .object(["state": .number(6)])),
            event("report_connected_server", .object(["longName": .string("USA - Seattle #13")])),
            event("report_connection_settings", .object(["algorithm": .string("SP"), "connection_secondary_speed_activation": .number(30), "startup_connect": .bool(true)])),
            event("report_networks", .array([
                .object(["guid": .string("cell"), "name": .string("Cellular"), "isp": .string("T-Mobile USA"), "type": .string("Cellular"), "priority": .number(0), "connectionState": .number(2)]),
                .object(["guid": .string("eth0"), "name": .string("Eth0"), "isp": .string("Starlink"), "type": .string("Ethernet"), "priority": .number(1), "offline": .bool(true), "connectionState": .number(0), "status": .string("SETTINGS PANE SESSION IPSTATS STATUS MSG MISALIGNED")])
            ])),
            event("report_connection_stats", .object(["connections": .array([
                .object(["guid": .string("cell"), "rcvBps": .number(66790), "sndBps": .number(21130)]),
                .object(["guid": .string("speedify"), "rcvBps": .number(1000), "sndBps": .number(2000), "totBps": .number(3000)])
            ])])),
            event("report_session_stats", .object([
                "0": .object(["bytes_recv": .number(19_144_109), "bytes_sent": .number(150_263_683)])
            ]))
        ])
        let client = RouterSpeedifyClient(socketFactory: StubSpeedifySocketFactory(socket: socket), timeout: 0.05)

        let status = try await client.status(host: "192.168.8.1")

        XCTAssertEqual(socket.connectedURL?.absoluteString, "ws://192.168.8.1/luci-app-speedify/api/ws")
        XCTAssertTrue(socket.sentEvents.contains("request_current_state"))
        XCTAssertTrue(socket.sentEvents.contains("request_connected_server"))
        XCTAssertTrue(socket.sentEvents.contains("request_connection_settings"))
        XCTAssertTrue(socket.sentEvents.contains("request_networks"))
        XCTAssertTrue(status.isAvailable)
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.state, "Connected")
        XCTAssertEqual(status.server, "United States - Seattle #13")
        XCTAssertEqual(status.bondingMode, .speed)
        XCTAssertEqual(status.secondaryThresholdMbps, 30)
        XCTAssertEqual(status.startupConnect, true)
        XCTAssertEqual(status.networks.map(\.displayName), ["Cellular (T-Mobile USA)", "Eth0 (Starlink)"])
        XCTAssertEqual(status.networks.map(\.priority), [.always, .secondary])
        XCTAssertEqual(status.networks.map(\.isConnected), [true, false])
        XCTAssertEqual(status.networks[0].receiveBps, 66790)
        XCTAssertEqual(status.networks[0].sendBps, 21130)
        XCTAssertEqual(status.networks[1].statusMessage, "SETTINGS PANE SESSION IPSTATS STATUS MSG MISALIGNED")
        XCTAssertEqual(status.sessionDownloadBytes, 19_144_109)
        XCTAssertEqual(status.sessionUploadBytes, 150_263_683)
        XCTAssertEqual(status.graphSamples.map(\.totalBps), [3000])
    }

    func testControlsSendSameEventsAsEmbeddedSpeedifyUI() async throws {
        let socket = StubSpeedifySocket(incoming: [])
        let client = RouterSpeedifyClient(socketFactory: StubSpeedifySocketFactory(socket: socket), timeout: 0.01)

        try await client.connect(host: "192.168.8.1", server: "auto")
        try await client.disconnect(host: "192.168.8.1")
        try await client.setBondingMode(.streaming, host: "192.168.8.1")
        try await client.setNetworkPriority(.never, networkID: "eth0", host: "192.168.8.1")

        XCTAssertEqual(socket.sentMessages.map(\.event), [
            "server_auto_connect",
            "server_disconnect",
            "set_connection_algorithm",
            "set_network_priority"
        ])
        XCTAssertEqual(socket.sentMessages[0].payload["server"], .string("auto"))
        XCTAssertEqual(socket.sentMessages[2].payload["algorithm"], .string("STR"))
        XCTAssertEqual(socket.sentMessages[3].payload["network"], .string("eth0"))
        XCTAssertEqual(socket.sentMessages[3].payload["priority"], .number(100))
    }

    private func event(_ name: String, _ payload: JSONValue) -> String {
        let value = JSONValue.array([.string(name), payload])
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}

private final class StubSpeedifySocketFactory: RouterSpeedifySocketFactory, @unchecked Sendable {
    let socket: StubSpeedifySocket

    init(socket: StubSpeedifySocket) {
        self.socket = socket
    }

    func makeSocket(url: URL) async throws -> RouterSpeedifySocket {
        socket.connectedURL = url
        return socket
    }
}

private final class StubSpeedifySocket: RouterSpeedifySocket, @unchecked Sendable {
    struct SentMessage: Equatable {
        var event: String
        var payload: JSONObject
    }

    var connectedURL: URL?
    var sentMessages: [SentMessage] = []
    private var incoming: [String]

    var sentEvents: [String] {
        sentMessages.map(\.event)
    }

    init(incoming: [String]) {
        self.incoming = incoming
    }

    func send(event: String, payload: JSONObject) async throws {
        sentMessages.append(SentMessage(event: event, payload: payload))
    }

    func receive() async throws -> String {
        guard !incoming.isEmpty else {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return ""
        }
        return incoming.removeFirst()
    }

    func close() async {}
}
