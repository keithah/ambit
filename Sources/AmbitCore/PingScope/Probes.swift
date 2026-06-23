import Foundation

/// A latency probe for one host. Implementations: TCPProbe/UDPProbe/ICMPProbe (added across
/// M1–M2), wrapped by TimeoutProbe.
public protocol PingProbe: Sendable {
    func measure(_ host: PingScopeHostConfig) async -> ProbeResult
}

/// Stands in for a probe method that isn't available in this build (e.g. ICMP on
/// sandboxed/App Store builds) — always reports the configured failure reason.
public struct UnavailableProbe: PingProbe {
    private let reason: ProbeFailureReason

    public init(reason: ProbeFailureReason) {
        self.reason = reason
    }

    public func measure(_ host: PingScopeHostConfig) async -> ProbeResult {
        ProbeResult(timestamp: Date(), failureReason: reason, note: "Probe method unavailable in this build")
    }
}

/// Wraps a probe and races it against the host's timeout; whichever finishes first wins and
/// the loser is cancelled. A timeout yields a `.timeout` failure (never a late/garbage value).
public struct TimeoutProbe: PingProbe {
    private let wrapped: any PingProbe

    public init(wrapping probe: any PingProbe) {
        self.wrapped = probe
    }

    public func measure(_ host: PingScopeHostConfig) async -> ProbeResult {
        let timeoutNanos = UInt64(max(0, host.timeout) * 1_000_000_000)
        return await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { [wrapped] in await wrapped.measure(host) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return nil
            }
            defer { group.cancelAll() }
            for await outcome in group {
                if let outcome { return outcome }            // probe finished first
                return ProbeResult(timestamp: Date(), failureReason: .timeout)  // timeout won
            }
            return ProbeResult(timestamp: Date(), failureReason: .timeout)
        }
    }
}
