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
        medianMs = Self.median(latencies)
        lastMs = recent.last?.latencyMs
        lossFraction = recent.isEmpty ? 0 : Double(recent.count - latencies.count) / Double(recent.count)
        consecutiveFailures = recent.reversed().prefix { !$0.succeeded }.count
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
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
    case checking, online, noNetwork, routerUnreachable, wifiSlow, internetDown, internetPartial, internetSlow, dnsFailing, connectionDown

    public var health: Health {
        switch self {
        case .checking: .unknown
        case .online: .online
        case .wifiSlow, .internetSlow: .degraded
        case .noNetwork, .routerUnreachable, .internetDown, .internetPartial, .dnsFailing, .connectionDown: .offline
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
        case .internetPartial: "The internet is only partly reachable"
        case .internetSlow: "Your internet provider is slow"
        case .dnsFailing: "DNS isn't working"
        case .connectionDown: "Offline"
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
        case .internetPartial: "Ambit's own checks fail, but one of your ping targets still answers from a public address. A sign-in page, a firewall or a partial outage may be in the way."
        case .internetSlow: "Your router is fine. The slowdown is beyond it."
        case .dnsFailing: "The internet is reachable, but names aren't resolving."
        case .connectionDown: "Your router doesn't answer pings, so Ambit can't tell which side failed."
        }
    }
}

/// Pure fault location: which hop is to blame given recent probe statistics.
///
/// `routerHasAnswered` says whether the current router has ever replied to a ping. A router that
/// never replies cannot be told apart from a dead one, so it is never named as the failing hop.
///
/// `targetAnswering` says that one of the user's ping targets on the internet answered just now.
/// It never makes the connection "online": the built-in checks decide that. It only changes what
/// an outage is called, because traffic is plainly getting past the router.
public func diagnose(
    hasGateway: Bool,
    routerHasAnswered: Bool = true,
    targetAnswering: Bool = false,
    router: HopStats,
    internet: HopStats,
    dns: HopStats,
    thresholds: DiagnosisThresholds = DiagnosisThresholds()
) -> Verdict {
    // No default route normally means no network, unless traffic is demonstrably passing (an
    // IPv6-only link, or a failed route lookup).
    let internetAnswering = internet.sampleCount > 0 && internet.consecutiveFailures == 0
    guard hasGateway || internetAnswering else { return .noNetwork }
    guard router.sampleCount > 0 || internet.sampleCount > 0 else { return .checking }

    let routerDown = router.sampleCount > 0 && router.consecutiveFailures >= thresholds.downAfter
    let internetDown = internet.sampleCount > 0 && internet.consecutiveFailures >= thresholds.downAfter
    let dnsDown = dns.sampleCount > 0 && dns.consecutiveFailures >= thresholds.downAfter

    if internetDown && targetAnswering { return .internetPartial }
    if routerDown && (internetDown || internet.sampleCount == 0) {
        if routerHasAnswered { return .routerUnreachable }
        return internetDown ? .connectionDown : .checking
    }
    if internetDown { return .internetDown }
    if dnsDown { return .dnsFailing }

    // The internet hop has not answered in this window and has not failed long enough to be
    // called down: say nothing yet rather than "Online".
    if internet.medianMs == nil { return .checking }

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
