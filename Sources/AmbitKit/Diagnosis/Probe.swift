import Foundation
import Network

public struct ProbeTarget: Sendable, Hashable {
    public var host: String
    public var port: UInt16?
    public var timeout: TimeInterval

    public init(host: String, port: UInt16? = nil, timeout: TimeInterval = 2) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    /// Hosts reach `/sbin/ping` as an argument, so anything that could be read as an option is rejected.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public enum ProbeFailure: String, Sendable, Equatable {
    case timeout, dns, unreachable, refused, invalidTarget, unknown
}

public struct ProbeSample: Sendable, Equatable {
    public var date: Date
    public var latencyMs: Double?
    public var failure: ProbeFailure?

    public init(date: Date = Date(), latencyMs: Double) {
        self.date = date
        self.latencyMs = latencyMs
        self.failure = nil
    }

    public init(date: Date = Date(), failure: ProbeFailure) {
        self.date = date
        self.latencyMs = nil
        self.failure = failure
    }

    public var succeeded: Bool { latencyMs != nil }
}

public protocol Probe: Sendable {
    func measure(_ target: ProbeTarget) async -> ProbeSample
}

/// Races a probe against the target's timeout. The loser is cancelled and never awaited, so a
/// wedged probe (for example an NWConnection stuck across sleep) cannot block the caller.
public struct TimeoutProbe: Probe {
    private let wrapped: any Probe

    public init(_ probe: any Probe) {
        self.wrapped = probe
    }

    public func measure(_ target: ProbeTarget) async -> ProbeSample {
        let nanos = UInt64(max(0, target.timeout) * 1_000_000_000)
        let gate = SingleResume()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ProbeSample, Never>) in
            let probeTask = Task { [wrapped] in
                let sample = await wrapped.measure(target)
                if gate.claim() { continuation.resume(returning: sample) }
            }
            Task {
                try? await Task.sleep(nanoseconds: nanos)
                if gate.claim() {
                    probeTask.cancel()
                    continuation.resume(returning: ProbeSample(failure: .timeout))
                }
            }
        }
    }
}

/// One ICMP echo via `/sbin/ping`. Self-bounded by `-W` (milliseconds on macOS) and the process timeout.
public struct ICMPProbe: Probe {
    private let executable: String
    private let runner: any ProcessRunner

    public init(executable: String = "/sbin/ping", runner: any ProcessRunner = SystemProcessRunner()) {
        self.executable = executable
        self.runner = runner
    }

    public func measure(_ target: ProbeTarget) async -> ProbeSample {
        guard ProbeTarget.isValidHost(target.host) else { return ProbeSample(failure: .invalidTarget) }
        let waitMs = max(1, Int((target.timeout * 1000).rounded()))
        do {
            let result = try await runner.run(
                executable: executable,
                arguments: ["-c", "1", "-W", "\(waitMs)", target.host],
                timeout: target.timeout + 1
            )
            if result.exitCode == 0, let ms = Self.parseLatencyMs(result.stdout) {
                return ProbeSample(latencyMs: ms)
            }
            return ProbeSample(failure: Self.classify(result))
        } catch {
            return ProbeSample(failure: .timeout)
        }
    }

    static func parseLatencyMs(_ output: String) -> Double? {
        guard let range = output.range(of: "time=") else { return nil }
        return Double(output[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    static func classify(_ result: ProcessResult) -> ProbeFailure {
        let text = (result.stdout + " " + result.stderr).lowercased()
        if text.contains("cannot resolve") || text.contains("unknown host") { return .dns }
        if text.contains("no route to host") || text.contains("network is unreachable")
            || text.contains("host is down") || text.contains("unreachable") {
            return .unreachable
        }
        return .timeout
    }
}

/// TCP connect time via the Network framework. Wrap in `TimeoutProbe`.
public struct TCPProbe: Probe {
    public init() {}

    public func measure(_ target: ProbeTarget) async -> ProbeSample {
        guard ProbeTarget.isValidHost(target.host),
              let rawPort = target.port, let port = NWEndpoint.Port(rawValue: rawPort) else {
            return ProbeSample(failure: .invalidTarget)
        }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let box = UncheckedSendableBox(connection)
        let resume = SingleResume()
        let start = DispatchTime.now()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProbeSample, Never>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resume.claim() {
                            let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
                            box.value.cancel()
                            continuation.resume(returning: ProbeSample(latencyMs: ms))
                        }
                    case .failed(let error), .waiting(let error):
                        if resume.claim() {
                            box.value.cancel()
                            continuation.resume(returning: ProbeSample(failure: Self.map(error)))
                        }
                    case .cancelled:
                        if resume.claim() {
                            continuation.resume(returning: ProbeSample(failure: .timeout))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: Self.queue)
            }
        } onCancel: {
            box.value.cancel()
        }
    }

    private static let queue = DispatchQueue(label: "com.hadm.ambit.tcpprobe")

    static func map(_ error: NWError) -> ProbeFailure {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EHOSTDOWN: return .unreachable
            case .ETIMEDOUT: return .timeout
            default: return .unknown
            }
        case .dns: return .dns
        default: return .unknown
        }
    }
}

/// Time to resolve a hostname with the system resolver. Wrap in `TimeoutProbe`.
public struct DNSProbe: Probe {
    public init() {}

    public func measure(_ target: ProbeTarget) async -> ProbeSample {
        guard ProbeTarget.isValidHost(target.host) else { return ProbeSample(failure: .invalidTarget) }
        let host = target.host
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let start = DispatchTime.now()
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &info)
                if let info { freeaddrinfo(info) }
                let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
                continuation.resume(returning: status == 0 ? ProbeSample(latencyMs: ms) : ProbeSample(failure: .dns))
            }
        }
    }
}
