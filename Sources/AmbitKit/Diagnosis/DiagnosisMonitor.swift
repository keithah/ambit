import Foundation

public struct DiagnosisConfig: Sendable {
    public var interval: TimeInterval = 5
    public var internetTargets = [ProbeTarget(host: "1.1.1.1", port: 443), ProbeTarget(host: "8.8.8.8", port: 443)]
    public var dnsHost = "apple.com"
    public var historyLimit = 360
    public var thresholds = DiagnosisThresholds()

    public init() {}
}

public struct DiagnosisSnapshot: Sendable, Equatable {
    public var verdict: Verdict = .checking
    public var since = Date()
    public var gateway: String?
    public var router = HopStats.empty
    public var internet = HopStats.empty
    public var dns = HopStats.empty
    /// Internet latency samples, oldest first. A nil latency is a failed probe.
    public var internetHistory: [ProbeSample] = []
    public var updated: Date?

    public init() {}
}

/// Probes router, internet and DNS on a fixed interval and publishes a verdict.
public actor DiagnosisMonitor {
    private let config: DiagnosisConfig
    private let gatewayFinder: any GatewayFinding
    private let icmp: any Probe
    private let tcp: any Probe
    private let dnsProbe: any Probe

    private var routerSamples: [ProbeSample] = []
    private var internetSamples: [ProbeSample] = []
    private var dnsSamples: [ProbeSample] = []
    private var snapshot = DiagnosisSnapshot()
    private var loop: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<DiagnosisSnapshot>.Continuation] = [:]

    public init(
        config: DiagnosisConfig = DiagnosisConfig(),
        gatewayFinder: any GatewayFinding = RouteGatewayFinder(),
        icmp: any Probe = ICMPProbe(),
        tcp: any Probe = TimeoutProbe(TCPProbe()),
        dns: any Probe = TimeoutProbe(DNSProbe())
    ) {
        self.config = config
        self.gatewayFinder = gatewayFinder
        self.icmp = icmp
        self.tcp = tcp
        self.dnsProbe = dns
    }

    public func snapshots() -> AsyncStream<DiagnosisSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runCycle()
                try? await Task.sleep(nanoseconds: UInt64(self.config.interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Runs one probe cycle now (used on wake and network change, and by tests).
    @discardableResult
    public func runCycle() async -> DiagnosisSnapshot {
        let gateway = await gatewayFinder.defaultGateway()
        if gateway != snapshot.gateway {
            routerSamples.removeAll()
        }

        async let routerSample: ProbeSample? = probeRouter(gateway)
        async let internetSample = probeInternet()
        async let dnsSample = dnsProbe.measure(ProbeTarget(host: config.dnsHost))

        if let sample = await routerSample { append(sample, to: &routerSamples) }
        append(await internetSample, to: &internetSamples)
        append(await dnsSample, to: &dnsSamples)

        var next = snapshot
        next.gateway = gateway
        next.router = HopStats(samples: routerSamples)
        next.internet = HopStats(samples: internetSamples)
        next.dns = HopStats(samples: dnsSamples)
        next.internetHistory = internetSamples
        next.updated = Date()
        let verdict = diagnose(
            hasGateway: gateway != nil,
            router: next.router, internet: next.internet, dns: next.dns,
            thresholds: config.thresholds
        )
        if verdict != next.verdict {
            next.verdict = verdict
            next.since = Date()
        }
        snapshot = next
        for continuation in continuations.values { continuation.yield(next) }
        return next
    }

    private func probeRouter(_ gateway: String?) async -> ProbeSample? {
        guard let gateway else { return nil }
        return await icmp.measure(ProbeTarget(host: gateway, timeout: 1))
    }

    /// The internet hop succeeds if any target answers; latency is the fastest answer.
    private func probeInternet() async -> ProbeSample {
        let tcp = self.tcp
        let samples = await withTaskGroup(of: ProbeSample.self) { group in
            for target in config.internetTargets {
                group.addTask { await tcp.measure(target) }
            }
            var collected: [ProbeSample] = []
            for await sample in group { collected.append(sample) }
            return collected
        }
        if let best = samples.compactMap(\.latencyMs).min() {
            return ProbeSample(latencyMs: best)
        }
        return ProbeSample(failure: samples.first?.failure ?? .unknown)
    }

    private func append(_ sample: ProbeSample, to samples: inout [ProbeSample]) {
        samples.append(sample)
        if samples.count > config.historyLimit {
            samples.removeFirst(samples.count - config.historyLimit)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
