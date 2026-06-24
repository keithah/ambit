import Foundation
import Network

/// Measures TCP connect latency (time to `.ready`) via the Network framework. Bound by
/// TimeoutProbe; on connection failure maps the NWError to a ProbeFailureReason.
public struct TCPProbe: PingProbe {
    public init() {}

    public func measure(_ host: PingHostConfig) async -> ProbeResult {
        guard let rawPort = host.port, let port = NWEndpoint.Port(rawValue: rawPort) else {
            return ProbeResult(timestamp: Date(), failureReason: .unknown, note: "TCP requires a port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host.address), port: port, using: .tcp)
        let box = UncheckedSendableBox(connection)
        let resume = SingleResume()
        let start = DispatchTime.now()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult, Never>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
                        if resume.claim() {
                            box.value.cancel()
                            continuation.resume(returning: ProbeResult(timestamp: Date(), latencyMs: ms))
                        }
                    case .failed(let error), .waiting(let error):
                        if resume.claim() {
                            box.value.cancel()
                            continuation.resume(returning: ProbeResult(timestamp: Date(), failureReason: Self.map(error)))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: Self.queue)
            }
        } onCancel: {
            if resume.claim() {
                box.value.cancel()
            }
        }
    }

    private static let queue = DispatchQueue(label: "ambit.pingscope.tcpprobe")

    static func map(_ error: NWError) -> ProbeFailureReason {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EHOSTDOWN: return .networkUnavailable
            case .ECANCELED: return .cancelled
            default: return .unknown
            }
        case .dns: return .dnsFailure
        default: return .unknown
        }
    }
}

/// Single-use resume guard: NWConnection's state handler can fire repeatedly, but the
/// continuation must resume exactly once.
final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Escape hatch to reference a non-Sendable value (NWConnection) inside @Sendable handlers.
final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
