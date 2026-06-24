import Foundation

/// Selects the probe implementation for a host's method.
public protocol ProbeFactory: Sendable {
    func makeProbe(for host: PingHostConfig) -> any PingProbe
}

public struct DefaultProbeFactory: ProbeFactory {
    private let allowsICMP: Bool
    private let icmpExecutable: String
    private let processRunner: any ProcessRunner

    public init(
        allowsICMP: Bool = true,
        icmpExecutable: String = "/sbin/ping",
        processRunner: any ProcessRunner = SystemProcessRunner()
    ) {
        self.allowsICMP = allowsICMP
        self.icmpExecutable = icmpExecutable
        self.processRunner = processRunner
    }

    public func makeProbe(for host: PingHostConfig) -> any PingProbe {
        switch host.method {
        case .tcp:
            return TimeoutProbe(wrapping: TCPProbe())
        case .udp:
            return TimeoutProbe(wrapping: UDPProbe())
        case .icmp:
            // ICMP self-bounds via ping's -W + process timeout, so it isn't TimeoutProbe-wrapped.
            return allowsICMP ? ICMPProbe(executable: icmpExecutable, processRunner: processRunner) : UnavailableProbe(reason: .icmpUnavailable)
        }
    }
}
