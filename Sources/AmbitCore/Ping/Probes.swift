import Foundation

/// A latency probe for one host. Implementations: TCPProbe/UDPProbe/ICMPProbe (added across
/// M1–M2), wrapped by TimeoutProbe.
public protocol PingProbe: Sendable {
    func measure(_ host: PingHostConfig) async -> ProbeResult
}

/// Stands in for a probe method that isn't available in this build (e.g. ICMP on
/// sandboxed/App Store builds) — always reports the configured failure reason.
public struct UnavailableProbe: PingProbe {
    private let reason: ProbeFailureReason

    public init(reason: ProbeFailureReason) {
        self.reason = reason
    }

    public func measure(_ host: PingHostConfig) async -> ProbeResult {
        ProbeResult(timestamp: Date(), failureReason: reason, note: "Probe method unavailable in this build")
    }
}

/// Wraps a probe and races it against the host's timeout; whichever finishes first wins. The
/// loser is abandoned (best-effort cancelled), NEVER awaited — so a wedged probe (e.g. an
/// NWConnection stuck across system sleep) cannot block the poll cycle. A timeout yields a
/// `.timeout` failure (never a late/garbage value).
public struct TimeoutProbe: PingProbe {
    private let wrapped: any PingProbe

    public init(wrapping probe: any PingProbe) {
        self.wrapped = probe
    }

    public func measure(_ host: PingHostConfig) async -> ProbeResult {
        let timeoutNanos = UInt64(max(0, host.timeout) * 1_000_000_000)
        let gate = SingleResume()
        // No structured group: the continuation returns the instant one side claims the gate;
        // the loser is never awaited. On deadline-win we cancel the in-flight probe and move on.
        return await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult, Never>) in
            let probeTask = Task { [wrapped] in
                let result = await wrapped.measure(host)
                if gate.claim() { continuation.resume(returning: result) }
            }
            let probeBox = UncheckedSendableBox(probeTask)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                if gate.claim() {
                    probeBox.value.cancel()   // best-effort; the probe's own SingleResume path cancels its NWConnection
                    continuation.resume(returning: ProbeResult(timestamp: Date(), failureReason: .timeout))
                }
            }
        }
    }
}
