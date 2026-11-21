import Foundation

/// Talks to a Starlink dish on the local network using gRPC-Web over plain HTTP (port 9201),
/// which needs only URLSession. Not yet verified against a physical dish: see docs/decisions.md.
public struct StarlinkClient: Sendable {
    public static let defaultHost = "192.168.100.1"

    private let endpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(host: String = StarlinkClient.defaultHost, port: Int = 9201, session: URLSession = .shared, timeout: TimeInterval = 4) {
        self.endpoint = URL(string: "http://\(host):\(port)/SpaceX.API.Device.Device/Handle")!
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

    private func call(_ message: Data) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.httpBody = GRPCWeb.frame(message)
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StarlinkError.unexpectedResponse }
        guard http.statusCode == 200 else { throw StarlinkError.http(http.statusCode) }
        // A call that fails before any message is sent reports its status in the HTTP headers.
        if let status = http.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init), status != 0 {
            throw StarlinkError.grpc(status: status, message: http.value(forHTTPHeaderField: "grpc-message") ?? "")
        }
        return try GRPCWeb.message(from: body)
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

    static func message(from body: Data) throws -> Data {
        var bytes = [UInt8](body)[...]
        var message: Data?
        while !bytes.isEmpty {
            guard bytes.count >= 5 else { throw StarlinkError.unexpectedResponse }
            let flag = bytes[bytes.startIndex]
            let length = bytes.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
            bytes = bytes.dropFirst(5)
            guard bytes.count >= length else { throw StarlinkError.unexpectedResponse }
            let payload = Data(bytes.prefix(length))
            bytes = bytes.dropFirst(length)
            if flag & 0x80 != 0 {
                let trailers = parseTrailers(payload)
                if let status = trailers["grpc-status"].flatMap(Int.init), status != 0 {
                    throw StarlinkError.grpc(status: status, message: trailers["grpc-message"] ?? "")
                }
            } else if message == nil {
                message = payload
            }
        }
        guard let message else { throw StarlinkError.unexpectedResponse }
        return message
    }

    static func parseTrailers(_ payload: Data) -> [String: String] {
        var trailers: [String: String] = [:]
        for line in String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            trailers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return trailers
    }
}
