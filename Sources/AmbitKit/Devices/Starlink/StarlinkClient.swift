import Foundation
import Network

/// Talks to a Starlink dish on the local network using gRPC-Web over plain HTTP (port 9201),
/// which needs only URLSession. Not yet verified against a physical dish: see docs/decisions.md.
public struct StarlinkClient: Sendable {
    public static let defaultHost = "192.168.100.1"

    private let endpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval

    /// `timeout` bounds the whole call, not only the gap between bytes.
    public init(host: String = StarlinkClient.defaultHost, port: Int = 9201, session: URLSession = .shared, timeout: TimeInterval = 4) throws {
        guard ProbeTarget.isValidHost(host), (1...65535).contains(port), timeout.isFinite, timeout > 0 else {
            throw StarlinkError.invalidHost
        }
        // A colon is valid only inside an IPv6 address, which a URL writes in brackets.
        var literal = host
        if host.contains(":") {
            guard IPv6Address(host) != nil else { throw StarlinkError.invalidHost }
            literal = "[\(host)]"
        }
        guard let url = URL(string: "http://\(literal):\(port)/SpaceX.API.Device.Device/Handle"), url.host != nil else {
            throw StarlinkError.invalidHost
        }
        self.endpoint = url
        self.session = session
        self.timeout = timeout
    }

    public func status() async throws -> StarlinkStatus {
        try StarlinkStatus(response: try await call(StarlinkRequest.getStatus))
    }

    public func reboot() async throws {
        _ = try await call(StarlinkRequest.reboot)
    }

    public func setStowed(_ stowed: Bool) async throws {
        _ = try await call(StarlinkRequest.stow(stowed))
    }

    /// Returns the `Response` message, after checking the HTTP, gRPC and device status in turn.
    private func call(_ message: Data) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.httpBody = GRPCWeb.frame(message)
        let (body, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw StarlinkError.unexpectedResponse }
        guard http.statusCode == 200 else { throw StarlinkError.http(http.statusCode) }
        // A call that fails before any message is sent reports its status in the HTTP headers.
        let headerStatus = http.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init)
        if let headerStatus, headerStatus != 0 {
            throw StarlinkError.grpc(status: headerStatus, message: GRPCWeb.decodeMessage(http.value(forHTTPHeaderField: "grpc-message")))
        }
        let reply = try GRPCWeb.message(from: body, headerStatus: headerStatus)
        try StarlinkError.checkDeviceStatus(in: reply)
        return reply
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = session
        let timeout = timeout
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw StarlinkError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw StarlinkError.unexpectedResponse }
            return first
        }
    }
}

/// gRPC-Web framing: each frame is a flag byte, a 4-byte big-endian length, then the payload.
/// Flag 0x00 is a message; 0x80 is the trailer block ("grpc-status: 0\r\n...").
enum GRPCWeb {
    static func frame(_ message: Data) -> Data {
        var out = Data([0])
        withUnsafeBytes(of: UInt32(message.count).bigEndian) { out.append(contentsOf: $0) }
        return out + message
    }

    /// Returns the first message. The call must also have ended with status 0, reported in the
    /// trailer frame or, failing that, in the HTTP headers (`headerStatus`); a body cut off before
    /// its trailers is not a success.
    static func message(from body: Data, headerStatus: Int? = nil) throws -> Data {
        var bytes = [UInt8](body)[...]
        var message: Data?
        var status = headerStatus
        while !bytes.isEmpty {
            guard bytes.count >= 5 else { throw StarlinkError.unexpectedResponse }
            let flag = bytes[bytes.startIndex]
            let length = bytes.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
            bytes = bytes.dropFirst(5)
            guard bytes.count >= length else { throw StarlinkError.unexpectedResponse }
            let payload = Data(bytes.prefix(length))
            bytes = bytes.dropFirst(length)
            switch flag {
            case 0x00:
                if message == nil { message = payload }
            case 0x80:
                // The trailer block ends the call: nothing may follow it, and any non-zero
                // status line in it is a failure.
                guard bytes.isEmpty else { throw StarlinkError.unexpectedResponse }
                let trailers = parseTrailers(payload)
                for code in trailers.statuses where code != 0 {
                    throw StarlinkError.grpc(status: code, message: decodeMessage(trailers.message))
                }
                if !trailers.statuses.isEmpty { status = 0 }
            default:
                // Compressed (0x01) or reserved flags: compression is never requested.
                throw StarlinkError.unexpectedResponse
            }
        }
        guard status == 0, let message else { throw StarlinkError.unexpectedResponse }
        return message
    }

    /// `grpc-message` is percent-encoded on the wire.
    static func decodeMessage(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw.removingPercentEncoding ?? raw
    }

    static func parseTrailers(_ payload: Data) -> (statuses: [Int], message: String?) {
        var statuses: [Int] = []
        var message: String?
        for line in String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() {
            case "grpc-status":
                // An unreadable status is not a success.
                statuses.append(Int(value) ?? -1)
            case "grpc-message": message = value
            default: break
            }
        }
        return (statuses, message)
    }
}
