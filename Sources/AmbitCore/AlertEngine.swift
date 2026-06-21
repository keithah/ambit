import Foundation

public struct AlertEvent: Equatable, Identifiable, Sendable {
    public var id: String
    public var ruleID: String
    public var providerID: ProviderID
    public var title: String
    public var message: String
    public var severity: AlertSeverity
    public var triggeredAt: Date

    public init(
        id: String = UUID().uuidString,
        ruleID: String,
        providerID: ProviderID,
        title: String,
        message: String,
        severity: AlertSeverity,
        triggeredAt: Date = Date()
    ) {
        self.id = id
        self.ruleID = ruleID
        self.providerID = providerID
        self.title = title
        self.message = message
        self.severity = severity
        self.triggeredAt = triggeredAt
    }
}

public enum AlertSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case critical
}

public enum AlertRule: Equatable, Sendable {
    case threshold(ThresholdAlertRule)
    case stateTransition(StateTransitionAlertRule)
    case sustained(SustainedAlertRule)

    var id: String {
        switch self {
        case .threshold(let rule): return rule.id
        case .stateTransition(let rule): return rule.id
        case .sustained(let rule): return rule.id
        }
    }

    public var providerID: ProviderID {
        switch self {
        case .threshold(let rule): return rule.providerID
        case .stateTransition(let rule): return rule.providerID
        case .sustained(let rule): return rule.providerID
        }
    }

    func evaluate(snapshot: EngineSnapshot, state: inout AlertRuleState, now: Date) -> AlertEvent? {
        switch self {
        case .threshold(let rule):
            return rule.evaluate(snapshot: snapshot, state: &state, now: now)
        case .stateTransition(let rule):
            return rule.evaluate(snapshot: snapshot, state: &state, now: now)
        case .sustained(let rule):
            return rule.evaluate(snapshot: snapshot, state: &state, now: now)
        }
    }
}

public struct ThresholdAlertRule: Equatable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var metricID: String
    public var comparison: AlertComparison
    public var threshold: Double
    public var title: String
    public var message: String
    public var severity: AlertSeverity

    public init(
        id: String,
        providerID: ProviderID,
        metricID: String,
        comparison: AlertComparison,
        threshold: Double,
        title: String,
        message: String,
        severity: AlertSeverity = .warning
    ) {
        self.id = id
        self.providerID = providerID
        self.metricID = metricID
        self.comparison = comparison
        self.threshold = threshold
        self.title = title
        self.message = message
        self.severity = severity
    }

    func evaluate(snapshot: EngineSnapshot, state: inout AlertRuleState, now: Date) -> AlertEvent? {
        guard let value = snapshot.numericMetric(providerID: providerID, metricID: metricID) else {
            state.activeRuleIDs.remove(id)
            return nil
        }
        let isActive = comparison.matches(value, threshold: threshold)
        return state.fireOnRisingEdge(
            ruleID: id,
            isActive: isActive,
            event: AlertEvent(ruleID: id, providerID: providerID, title: title, message: message, severity: severity, triggeredAt: now)
        )
    }
}

public struct StateTransitionAlertRule: Equatable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var metricID: String
    public var expectedValue: MetricValue
    public var title: String
    public var message: String
    public var severity: AlertSeverity

    public init(
        id: String,
        providerID: ProviderID,
        metricID: String,
        expectedValue: MetricValue,
        title: String,
        message: String,
        severity: AlertSeverity = .warning
    ) {
        self.id = id
        self.providerID = providerID
        self.metricID = metricID
        self.expectedValue = expectedValue
        self.title = title
        self.message = message
        self.severity = severity
    }

    func evaluate(snapshot: EngineSnapshot, state: inout AlertRuleState, now: Date) -> AlertEvent? {
        let value = snapshot.metric(providerID: providerID, metricID: metricID)?.value
        let previous = state.lastMetricValues[id]
        state.lastMetricValues[id] = value
        guard value == expectedValue, previous != nil, previous != expectedValue else { return nil }
        return AlertEvent(ruleID: id, providerID: providerID, title: title, message: message, severity: severity, triggeredAt: now)
    }
}

public struct SustainedAlertRule: Equatable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var metricID: String
    public var comparison: AlertComparison
    public var threshold: Double
    public var duration: TimeInterval
    public var title: String
    public var message: String
    public var severity: AlertSeverity

    public init(
        id: String,
        providerID: ProviderID,
        metricID: String,
        comparison: AlertComparison,
        threshold: Double,
        duration: TimeInterval,
        title: String,
        message: String,
        severity: AlertSeverity = .warning
    ) {
        self.id = id
        self.providerID = providerID
        self.metricID = metricID
        self.comparison = comparison
        self.threshold = threshold
        self.duration = duration
        self.title = title
        self.message = message
        self.severity = severity
    }

    func evaluate(snapshot: EngineSnapshot, state: inout AlertRuleState, now: Date) -> AlertEvent? {
        guard let value = snapshot.numericMetric(providerID: providerID, metricID: metricID),
              comparison.matches(value, threshold: threshold)
        else {
            state.sustainedStartByRuleID[id] = nil
            state.activeRuleIDs.remove(id)
            return nil
        }

        let started = state.sustainedStartByRuleID[id] ?? now
        state.sustainedStartByRuleID[id] = started
        let isActive = now.timeIntervalSince(started) >= duration
        return state.fireOnRisingEdge(
            ruleID: id,
            isActive: isActive,
            event: AlertEvent(ruleID: id, providerID: providerID, title: title, message: message, severity: severity, triggeredAt: now)
        )
    }
}

public enum AlertComparison: String, Codable, Equatable, Sendable {
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case equal

    func matches(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThan: return value > threshold
        case .greaterThanOrEqual: return value >= threshold
        case .lessThan: return value < threshold
        case .lessThanOrEqual: return value <= threshold
        case .equal: return value == threshold
        }
    }
}

public actor AlertEngine {
    private let rules: [AlertRule]
    private var state = AlertRuleState()

    public init(rules: [AlertRule] = AlertRule.defaultRules) {
        self.rules = rules
    }

    public func evaluate(_ snapshot: EngineSnapshot, now: Date = Date()) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for rule in rules {
            if let event = rule.evaluate(snapshot: snapshot, state: &state, now: now) {
                events.append(event)
            }
        }
        return events
    }
}

struct AlertRuleState: Sendable {
    var activeRuleIDs: Set<String> = []
    var sustainedStartByRuleID: [String: Date] = [:]
    var lastMetricValues: [String: MetricValue?] = [:]

    mutating func fireOnRisingEdge(ruleID: String, isActive: Bool, event: AlertEvent) -> AlertEvent? {
        if isActive {
            guard !activeRuleIDs.contains(ruleID) else { return nil }
            activeRuleIDs.insert(ruleID)
            return event
        }
        activeRuleIDs.remove(ruleID)
        return nil
    }
}

public extension AlertRule {
    static let defaultRules: [AlertRule] = [
        .threshold(ThresholdAlertRule(
            id: "starlink.obstruction.high",
            providerID: ProviderIDs.starlink,
            metricID: "obstruction_percent",
            comparison: .greaterThan,
            threshold: 5,
            title: "Starlink obstruction high",
            message: "Starlink obstruction is above 5%.",
            severity: .warning
        )),
        .stateTransition(StateTransitionAlertRule(
            id: "vpn.disconnected",
            providerID: ProviderIDs.vpn,
            metricID: "connected",
            expectedValue: .bool(false),
            title: "VPN disconnected",
            message: "The router VPN is no longer connected.",
            severity: .warning
        )),
        .sustained(SustainedAlertRule(
            id: "ecoflow.battery.low",
            providerID: ProviderIDs.ecoflow,
            metricID: "battery_percent",
            comparison: .lessThan,
            threshold: 20,
            duration: 60,
            title: "EcoFlow battery low",
            message: "EcoFlow battery has been below 20%.",
            severity: .critical
        ))
    ]
}

public extension EngineSnapshot {
    func provider(_ providerID: ProviderID) -> ProviderSnapshot? {
        providers[providerID]?.value
    }

    func metric(providerID: ProviderID, metricID: String) -> Metric? {
        provider(providerID)?.metrics.first { $0.id == metricID }
    }

    func numericMetric(providerID: ProviderID, metricID: String) -> Double? {
        metric(providerID: providerID, metricID: metricID)?.value.numericValue
    }
}

public extension MetricValue {
    var numericValue: Double? {
        switch self {
        case .throughput(let bitsPerSecond):
            return Double(bitsPerSecond)
        case .latency(let ms):
            return ms
        case .percent(let value), .level(let value):
            return value
        case .bool(let value):
            return value ? 1 : 0
        case .text:
            return nil
        }
    }
}
