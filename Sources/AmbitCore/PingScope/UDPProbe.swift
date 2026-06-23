import Foundation
import Network

/// Measures UDP send latency: connects and sends a single datagram, timing to send
/// completion. A UDP response is not guaranteed, so this reflects local send readiness, not a
/// round trip (mirrors the oracle). Bound by TimeoutProbe.
public struct UDPProbe: PingProbe {
    public init() {}

    public func measure(_ host: PingScopeHostConfig) async -> ProbeResult {
        guard let rawPort = host.port, let port = NWEndpoint.Port(rawValue: rawPort) else {
            return ProbeResult(timestamp: Date(), failureReason: .unknown, note: "UDP requires a port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host.address), port: port, using: .udp)
        let box = UncheckedSendableBox(connection)
        let resume = SingleResume()
        let start = DispatchTime.now()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult, Never>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.value.send(content: Data([0]), completion: .contentProcessed { error in
                            guard resume.claim() else { return }
                            box.value.cancel()
                            if let error {
                                continuation.resume(returning: ProbeResult(timestamp: Date(), failureReason: TCPProbe.map(error)))
                            } else {
                                let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
                                continuation.resume(returning: ProbeResult(timestamp: Date(), latencyMs: ms, note: "UDP response not guaranteed"))
                            }
                        })
                    case .failed(let error), .waiting(let error):
                        if resume.claim() {
                            box.value.cancel()
                            continuation.resume(returning: ProbeResult(timestamp: Date(), failureReason: TCPProbe.map(error)))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: Self.queue)
            }
        } onCancel: {
            if resume.claim() { box.value.cancel() }
        }
    }

    private static let queue = DispatchQueue(label: "ambit.pingscope.udpprobe")
}
