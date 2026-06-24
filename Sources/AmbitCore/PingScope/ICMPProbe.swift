import Foundation

/// Measures ICMP echo latency via `/sbin/ping` (one echo). Self-bounded by ping's `-W`
/// (milliseconds on macOS) plus the process timeout, so it isn't wrapped in TimeoutProbe.
/// Only available on non-sandboxed (Developer ID) builds; the factory substitutes
/// UnavailableProbe elsewhere.
public struct ICMPProbe: PingProbe {
    private let executable: String
    private let processRunner: any ProcessRunner

    public init(executable: String = "/sbin/ping", processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.executable = executable
        self.processRunner = processRunner
    }

    public func measure(_ host: PingHostConfig) async -> ProbeResult {
        let waitMs = Int((host.timeout * 1000).rounded())
        let arguments = ["-c", "1", "-W", "\(waitMs)", host.address]
        do {
            let result = try await processRunner.run(executable: executable, arguments: arguments, timeout: host.timeout + 1)
            if result.exitCode == 0, let ms = Self.parseLatencyMs(result.stdout) {
                return ProbeResult(timestamp: Date(), latencyMs: ms)
            }
            return ProbeResult(timestamp: Date(), failureReason: Self.classify(result), note: Self.note(result))
        } catch {
            return ProbeResult(timestamp: Date(), failureReason: .timeout)
        }
    }

    /// Extracts the latency from a `time=12.100 ms` token in ping output.
    static func parseLatencyMs(_ output: String) -> Double? {
        guard let range = output.range(of: "time=") else { return nil }
        let digits = output[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    static func classify(_ result: ProcessResult) -> ProbeFailureReason {
        let text = (result.stdout + " " + result.stderr).lowercased()
        if text.contains("cannot resolve") || text.contains("unknown host") || text.contains("name or service not known") {
            return .dnsFailure
        }
        return .timeout
    }

    private static func note(_ result: ProcessResult) -> String? {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? nil : stderr
    }
}
