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
        #expect(throws: ProtoError.self) { try StarlinkStatus(response: onlineResponse.dropLast(3)) }
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

    @Test func throwsOnATruncatedFrame() {
        #expect(throws: StarlinkError.unexpectedResponse) { try GRPCWeb.message(from: Data([0, 0, 0, 0, 9, 1, 2])) }
        #expect(throws: StarlinkError.unexpectedResponse) { try GRPCWeb.message(from: Data()) }
    }
}
