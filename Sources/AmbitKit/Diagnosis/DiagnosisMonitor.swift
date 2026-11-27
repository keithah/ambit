import Foundation

public struct DiagnosisConfig: Sendable {
    public var interval: TimeInterval = 5
    /// Any one answering counts as reachable. The IPv6 literal keeps IPv6-only links diagnosable
    /// without depending on DNS.
    public var internetTargets = [
        ProbeTarget(host: "1.1.1.1", port: 443),
        ProbeTarget(host: "8.8.8.8", port: 443),
        ProbeTarget(host: "2606:4700:4700::1111", port: 443),
    ]
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
    /// How many probe cycles have finished. Each adds one sample to the end of `internetHistory`.
    public var cycles = 0

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
    /// Chart history survives a network change; the diagnosis windows above do not.
    private var chartHistory: [ProbeSample] = []
    private var routerHasAnswered = false
    /// The latest answer from each ping target that is on the internet, by the target's name.
    private var targetAnswers: [String: ProbeSample] = [:]
    /// Answers from before this time came over another network and are not counted.
    private var answersCountFrom = Date.distantPast
    private var inFlight: Task<DiagnosisSnapshot, Never>?
    private var generation = 0
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
        // Only the latest snapshot matters to a display, so a slow consumer never builds a backlog.
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(snapshot)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Puts earlier samples, oldest first, on the graph before the first probe. Used at launch
    /// with what the last run stored. Does nothing once there are samples.
    public func seed(history: [ProbeSample]) {
        guard chartHistory.isEmpty else { return }
        chartHistory = Array(history.suffix(config.historyLimit))
        snapshot.internetHistory = chartHistory
    }

    /// Takes a ping target's latest sample as evidence for the diagnosis. A recent answer from an
    /// address on the internet shows that traffic gets past the router, which changes what an
    /// outage is called (see `diagnose`). A target that does not answer, or answers from a local
    /// address, shows nothing either way: it may be switched off, or on this network.
    public func report(_ sample: ProbeSample, fromTarget name: String) {
        if sample.succeeded, let address = sample.answeredFrom, ProbeTarget.isOnTheInternet(ipv4: address) {
            targetAnswers[name] = sample
        } else {
            targetAnswers[name] = nil
        }
    }

    public func forget(target name: String) {
        targetAnswers[name] = nil
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
        generation += 1
    }

    /// Runs one probe cycle now (used on wake and network change, and by tests). Cycles never
    /// overlap: a call made while one is in flight waits for that cycle's result.
    @discardableResult
    public func runCycle() async -> DiagnosisSnapshot {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.performCycle() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func performCycle() async -> DiagnosisSnapshot {
        let startedIn = generation
        // A failed lookup keeps the last known gateway instead of looking like a network change.
        let gateway: String?
        do { gateway = try await gatewayFinder.defaultGateway() } catch { gateway = snapshot.gateway }

        async let routerProbe: ProbeSample? = probeRouter(gateway)
        async let internetProbe = probeInternet()
        async let dnsProbeResult = dnsProbe.measure(ProbeTarget(host: config.dnsHost))
        let (routerSample, internetSample, dnsSample) = await (routerProbe, internetProbe, dnsProbeResult)

        // A cycle that was still probing when the monitor stopped commits nothing.
        guard startedIn == generation else { return snapshot }

        if gateway != snapshot.gateway {
            // Samples from the previous network say nothing about this one.
            routerSamples.removeAll()
            internetSamples.removeAll()
            dnsSamples.removeAll()
            routerHasAnswered = false
            targetAnswers.removeAll()
            // Leaving a network is what makes earlier answers stale; the first network is not a change.
            if snapshot.gateway != nil { answersCountFrom = Date() }
        }
        if let routerSample {
            append(routerSample, to: &routerSamples)
            if routerSample.succeeded { routerHasAnswered = true }
        }
        append(internetSample, to: &internetSamples)
        append(dnsSample, to: &dnsSamples)
        append(internetSample, to: &chartHistory)

        var next = snapshot
        next.gateway = gateway
        next.router = HopStats(samples: routerSamples)
        next.internet = HopStats(samples: internetSamples)
        next.dns = HopStats(samples: dnsSamples)
        next.internetHistory = chartHistory
        next.updated = Date()
        next.cycles += 1
        // Ping targets are pinged on their own schedule; only a recent answer counts.
        let now = Date()
        let targetAnswering = targetAnswers.values.contains { answer in
            answer.date >= answersCountFrom && (0...config.interval * 3).contains(now.timeIntervalSince(answer.date))
        }
        let verdict = diagnose(
            hasGateway: gateway != nil, routerHasAnswered: routerHasAnswered, targetAnswering: targetAnswering,
            router: next.router, internet: next.internet, dns: next.dns,
            thresholds: config.thresholds
        )
        if verdict != next.verdict {
            // An outage that gets another name is still the same outage, with the same start.
            if !(verdict.health == .offline && next.verdict.health == .offline) { next.since = Date() }
            next.verdict = verdict
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
