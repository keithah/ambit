import Foundation

/// Summary of the recent samples for one hop.
public struct HopStats: Sendable, Equatable {
    public var sampleCount: Int
    public var medianMs: Double?
    public var lastMs: Double?
    public var lossFraction: Double
    public var consecutiveFailures: Int

    public static let empty = HopStats(sampleCount: 0, medianMs: nil, lastMs: nil, lossFraction: 0, consecutiveFailures: 0)

    public init(sampleCount: Int, medianMs: Double?, lastMs: Double?, lossFraction: Double, consecutiveFailures: Int) {
        self.sampleCount = sampleCount
        self.medianMs = medianMs
        self.lastMs = lastMs
        self.lossFraction = lossFraction
        self.consecutiveFailures = consecutiveFailures
    }

    /// `samples` oldest first; only the last `window` are considered.
    public init(samples: [ProbeSample], window: Int = 12) {
        let recent = Array(samples.suffix(window))
        let latencies = recent.compactMap(\.latencyMs).sorted()
        sampleCount = recent.count
        medianMs = latencies.isEmpty ? nil : latencies[latencies.count / 2]
        lastMs = recent.last?.latencyMs
        lossFraction = recent.isEmpty ? 0 : Double(recent.count - latencies.count) / Double(recent.count)
        consecutiveFailures = recent.reversed().prefix { !$0.succeeded }.count
    }
}

public struct DiagnosisThresholds: Sendable, Equatable {
    public var downAfter = 3
    public var routerSlowMs = 60.0
    public var internetSlowMs = 250.0
    public var lossy = 0.25
    /// Loss is only judged once this many samples exist, so one early failure is not "100% loss".
    public var minSamplesForLoss = 4

    public init() {}
}

public enum Health: Sendable, Equatable {
    case unknown, online, degraded, offline
}

public enum Verdict: String, Sendable, Equatable, CaseIterable {
    case checking, online, noNetwork, routerUnreachable, wifiSlow, internetDown, internetSlow, dnsFailing

    public var health: Health {
        switch self {
        case .checking: .unknown
        case .online: .online
        case .wifiSlow, .internetSlow: .degraded
        case .noNetwork, .routerUnreachable, .internetDown, .dnsFailing: .offline
        }
    }

    public var title: String {
        switch self {
        case .checking: "Checking your connection"
        case .online: "Online"
        case .noNetwork: "Not connected to a network"
        case .routerUnreachable: "Can't reach your router"
        case .wifiSlow: "Your Wi-Fi or router is slow"
        case .internetDown: "Your internet provider is down"
        case .internetSlow: "Your internet provider is slow"
        case .dnsFailing: "DNS isn't working"
        }
    }

    public var detail: String {
        switch self {
        case .checking: "First results in a few seconds."
        case .online: "Router and internet are responding normally."
        case .noNetwork: "Join a Wi-Fi network or plug in a cable."
        case .routerUnreachable: "The problem is between this Mac and the router."
        case .wifiSlow: "The link to your router is slow or dropping packets."
        case .internetDown: "Your router is fine. The problem is beyond it."
        case .internetSlow: "Your router is fine. The slowdown is beyond it."
        case .dnsFailing: "The internet is reachable, but names aren't resolving."
        }
    }
}

/// Pure fault location: which hop is to blame given recent probe statistics.
public func diagnose(
    hasGateway: Bool,
    router: HopStats,
    internet: HopStats,
    dns: HopStats,
    thresholds: DiagnosisThresholds = DiagnosisThresholds()
) -> Verdict {
    guard hasGateway else { return .noNetwork }
    guard router.sampleCount > 0 || internet.sampleCount > 0 else { return .checking }

    let routerDown = router.sampleCount > 0 && router.consecutiveFailures >= thresholds.downAfter
    let internetDown = internet.sampleCount > 0 && internet.consecutiveFailures >= thresholds.downAfter
    let dnsDown = dns.sampleCount > 0 && dns.consecutiveFailures >= thresholds.downAfter

    // A router that ignores pings but passes traffic is not at fault.
    if routerDown && (internetDown || internet.sampleCount == 0) { return .routerUnreachable }
    if internetDown { return .internetDown }
    if dnsDown { return .dnsFailing }

    func lossy(_ hop: HopStats) -> Bool {
        hop.sampleCount >= thresholds.minSamplesForLoss && hop.lossFraction >= thresholds.lossy
    }
    if !routerDown, router.sampleCount > 0,
       (router.medianMs ?? 0) > thresholds.routerSlowMs || lossy(router) {
        return .wifiSlow
    }
    if (internet.medianMs ?? 0) > thresholds.internetSlowMs || lossy(internet) {
        return .internetSlow
    }
    return .online
}
