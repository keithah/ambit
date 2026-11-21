import Foundation
import Testing
@testable import AmbitKit

// Fixtures were produced with `protoc --encode=SpaceX.API.Device.Response` from the published
// dish schema, so these tests check the hand-written decoder against the real wire format.
private let onlineResponse = Data(base64Encoded:
    "CAeifWsKPwocdXQwMTAwMDAwMC0wMDAwMDAwMC0wMGFiY2RlZhILbWluaTFfcHJvZDIaEjIwMjYuMTEuMDUubXIxMjM0NRIECLDbEN0+CtcjPOI+BQ1vEgM7/T74awdNhT9AVIlLjT8AABpCwD/oBw==")!
private let outageResponse = Data(base64Encoded:
    "CAiifTwKHgocdXQwMTAwMDAwMC0wMDAwMDAwMC0wMGFiY2RlZhICCAziPgcNUriePigBkD8Bsj8ICAYQ6AcY0A8=")!

@Suite struct StarlinkStatusTests {
    @Test func decodesAnOnlineDish() throws {
        let status = try StarlinkStatus(response: onlineResponse)
        #expect(status.deviceID == "ut01000000-00000000-00abcdef")
        #expect(status.hardwareVersion == "mini1_prod2")
        #expect(status.softwareVersion == "2026.11.05.mr12345")
        #expect(status.uptimeSeconds == 273_840)
        #expect(status.latencyMs == 38.5)
        #expect(status.downlinkBps == 142_000_000)
        #expect(status.uplinkBps == 18_000_000)
        #expect(abs((status.dropRate ?? 0) - 0.01) < 1e-6)
        #expect(abs((status.fractionObstructed ?? 0) - 0.002) < 1e-6)
        #expect(!status.currentlyObstructed)
        #expect(!status.stowRequested)
        #expect(status.isOnline)
    }

    @Test func decodesAnOutage() throws {
        let status = try StarlinkStatus(response: outageResponse)
        #expect(status.outage == .obstructed)
        #expect(!status.isOnline)
        #expect(status.currentlyObstructed)
        #expect(status.stowRequested)
        #expect(status.uptimeSeconds == 12)
        #expect(status.latencyMs == nil)
    }

    @Test func rejectsAResponseWithoutDishStatus() {
        #expect(throws: StarlinkError.unexpectedResponse) { try StarlinkStatus(response: Data([0x08, 0x07])) }
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: StarlinkError.unexpectedResponse) { try StarlinkStatus(response: onlineResponse.dropLast(3)) }
    }

    @Test func aNegativeDeviceCodeIsAnErrorNotACrash() {
        // Response { status { code: -1 } }: an int32 -1 is a ten-byte varint.
        let status = Data([0x08]) + Data(repeating: 0xFF, count: 9) + Data([0x01])
        #expect(throws: StarlinkError.device(code: -1, message: "")) {
            try StarlinkStatus(response: ProtoWire.message(field: 2, status))
        }
    }

    @Test func anOutOfRangeOutageCauseIsUnknown() throws {
        let cause = Data([0x08]) + Data(repeating: 0xFF, count: 9) + Data([0x01])
        let dish = ProtoWire.message(field: 1014, cause)
        let status = try StarlinkStatus(response: ProtoWire.message(field: 2004, dish))
        #expect(status.outage == .unknown)
    }

    @Test func absentZeroValuedReadingsAreZero() throws {
        // A clear-sky idle dish sends no obstruction, drop-rate or throughput fields.
        let status = try StarlinkStatus(response: ProtoWire.message(field: 2004, Data()))
        #expect(status.fractionObstructed == 0)
        #expect(status.dropRate == 0)
        #expect(status.downlinkBps == 0)
        #expect(status.uplinkBps == 0)
        #expect(status.latencyMs == nil)
        #expect(status.isOnline)
    }

    @Test func surfacesADeviceError() {
        // Response { status { code: 7 message: "denied" } }
        let body = ProtoWire.bool(field: 1, true).dropLast() + Data([7]) + Data([0x12, 6]) + Data("denied".utf8)
        let response = ProtoWire.message(field: 2, Data(body))
        #expect(throws: StarlinkError.device(code: 7, message: "denied")) { try StarlinkStatus(response: response) }
    }

    @Test func requestsMatchProtocEncoding() {
        #expect(StarlinkRequest.getStatus == Data([0xE2, 0x3E, 0x00]))
        #expect(StarlinkRequest.reboot == Data([0xCA, 0x3E, 0x00]))
        #expect(StarlinkRequest.stow(true) == Data([0x92, 0x7D, 0x00]))
        #expect(StarlinkRequest.stow(false) == Data([0x92, 0x7D, 0x02, 0x08, 0x01]))
    }
}

@Suite struct GRPCWebTests {
    @Test func framesAMessage() {
        #expect(GRPCWeb.frame(Data([0xE2, 0x3E, 0x00])) == Data([0, 0, 0, 0, 3, 0xE2, 0x3E, 0x00]))
    }

    @Test func extractsTheMessageAndAcceptsOKTrailers() throws {
        let trailers = Data("grpc-status: 0\r\ngrpc-message: \r\n".utf8)
        var body = GRPCWeb.frame(onlineResponse)
        body.append(0x80)
        withUnsafeBytes(of: UInt32(trailers.count).bigEndian) { body.append(contentsOf: $0) }
        body.append(trailers)
        #expect(try GRPCWeb.message(from: body) == onlineResponse)
    }

    @Test func throwsOnANonZeroGRPCStatus() {
        let trailers = Data("grpc-status:12\r\ngrpc-message:Unimplemented\r\n".utf8)
        var body = Data([0x80])
        withUnsafeBytes(of: UInt32(trailers.count).bigEndian) { body.append(contentsOf: $0) }
        body.append(trailers)
        #expect(throws: StarlinkError.grpc(status: 12, message: "Unimplemented")) { try GRPCWeb.message(from: body) }
    }

    @Test func aBodyWithoutATerminalStatusIsNotSuccess() throws {
        #expect(throws: StarlinkError.unexpectedResponse) { try GRPCWeb.message(from: GRPCWeb.frame(onlineResponse)) }
        // Trailers present but with no grpc-status.
        #expect(throws: StarlinkError.unexpectedResponse) {
            try GRPCWeb.message(from: GRPCWeb.frame(onlineResponse) + trailerFrame("x-other: 1\r\n"))
        }
        // The status may instead come from the HTTP headers.
        #expect(try GRPCWeb.message(from: GRPCWeb.frame(onlineResponse), headerStatus: 0) == onlineResponse)
    }

    @Test func rejectsACompressedFrame() {
        var body = GRPCWeb.frame(onlineResponse)
        body[0] = 0x01
        #expect(throws: StarlinkError.unexpectedResponse) {
            try GRPCWeb.message(from: body + trailerFrame("grpc-status: 0\r\n"))
        }
    }

    @Test func decodesThePercentEncodedMessage() {
        #expect(throws: StarlinkError.grpc(status: 7, message: "not allowed")) {
            try GRPCWeb.message(from: trailerFrame("grpc-status: 7\r\ngrpc-message: not%20allowed\r\n"))
        }
    }

    @Test func throwsOnATruncatedFrame() {
        #expect(throws: StarlinkError.unexpectedResponse) { try GRPCWeb.message(from: Data([0, 0, 0, 0, 9, 1, 2])) }
        #expect(throws: StarlinkError.unexpectedResponse) { try GRPCWeb.message(from: Data()) }
    }
}

private func trailerFrame(_ text: String) -> Data {
    let trailers = Data(text.utf8)
    var frame = Data([0x80])
    withUnsafeBytes(of: UInt32(trailers.count).bigEndian) { frame.append(contentsOf: $0) }
    return frame + trailers
}

@Suite struct ProtoWireTests {
    @Test func rejectsAVarintThatOverflows64Bits() throws {
        // Field 1, varint whose tenth byte carries more than the top bit.
        let overlong = Data([0x08]) + Data(repeating: 0xFF, count: 9) + Data([0x02])
        #expect(throws: ProtoError.self) { try ProtoWire.fields(overlong) }
        let maximum = Data([0x08]) + Data(repeating: 0xFF, count: 9) + Data([0x01])
        #expect(try ProtoWire.fields(maximum) == [ProtoField(number: 1, value: .varint(.max))])
    }

    @Test func rejectsALengthPastTheEndAndUnsupportedWireTypes() {
        #expect(throws: ProtoError.self) { try ProtoWire.fields(Data([0x0A, 0x05, 0x01])) }
        #expect(throws: ProtoError.self) { try ProtoWire.fields(Data([0x0B])) }
        #expect(throws: ProtoError.self) { try ProtoWire.fields(Data([0x00, 0x01])) }
    }
}

/// Answers requests by host name, so tests running in parallel do not see each other's replies.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [String: URLRequest] = [:]

    static func session(host: String, reply: Reply) -> URLSession {
        lock.withLock { replies[host] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func request(host: String) -> URLRequest? { lock.withLock { seen[host] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen[host] = request
            return Self.replies[host]
        }
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite struct StarlinkClientTests {
    private func client(_ host: String, _ reply: StubProtocol.Reply, timeout: TimeInterval = 4) throws -> StarlinkClient {
        try StarlinkClient(host: host, session: StubProtocol.session(host: host, reply: reply), timeout: timeout)
    }

    private let okTrailers = trailerFrame("grpc-status: 0\r\n")

    @Test func readsStatusAndSendsGRPCWebHeaders() async throws {
        let host = "dish-ok.test"
        let status = try await client(host, .init(body: GRPCWeb.frame(onlineResponse) + okTrailers)).status()
        #expect(status.latencyMs == 38.5)
        let request = try #require(StubProtocol.request(host: host))
        #expect(request.url?.absoluteString == "http://dish-ok.test:9201/SpaceX.API.Device.Device/Handle")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/grpc-web+proto")
        #expect(request.value(forHTTPHeaderField: "X-Grpc-Web") == "1")
    }

    @Test func aCommandTheDishRefusesIsAnError() async throws {
        // HTTP 200 and grpc-status 0, but Response { status { code: 7 } }.
        let refused = ProtoWire.message(field: 2, Data([0x08, 0x07]))
        let reply = StubProtocol.Reply(body: GRPCWeb.frame(refused) + okTrailers)
        await #expect(throws: StarlinkError.device(code: 7, message: "")) {
            try await client("dish-refuses-reboot.test", reply).reboot()
        }
        await #expect(throws: StarlinkError.device(code: 7, message: "")) {
            try await client("dish-refuses-stow.test", reply).setStowed(true)
        }
    }

    @Test func aCommandTheDishAcceptsSucceeds() async throws {
        let accepted = ProtoWire.message(field: 2001, Data())
        try await client("dish-accepts.test", .init(body: GRPCWeb.frame(accepted) + okTrailers)).reboot()
    }

    @Test func reportsHTTPAndHeaderGRPCFailures() async throws {
        await #expect(throws: StarlinkError.http(503)) {
            try await client("dish-503.test", .init(status: 503)).status()
        }
        let reply = StubProtocol.Reply(headers: ["grpc-status": "12", "grpc-message": "no%20such%20method"])
        await #expect(throws: StarlinkError.grpc(status: 12, message: "no such method")) {
            try await client("dish-unimplemented.test", reply).status()
        }
    }

    @Test func givesUpAfterTheTimeout() async throws {
        let reply = StubProtocol.Reply(body: GRPCWeb.frame(onlineResponse) + okTrailers, delay: 5)
        await #expect(throws: StarlinkError.timedOut) {
            try await client("dish-slow.test", reply, timeout: 0.2).status()
        }
    }

    @Test func rejectsHostsThatCannotFormAnAddress() throws {
        for host in ["", "bad host", "a/b", "-flag", "host?x=1"] {
            #expect(throws: StarlinkError.invalidHost) { try StarlinkClient(host: host) }
        }
        #expect(throws: StarlinkError.invalidHost) { try StarlinkClient(port: 0) }
        _ = try StarlinkClient(host: "fe80::1")
        _ = try StarlinkClient(host: "dishy.starlink.com")
    }
}
