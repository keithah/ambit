import Foundation

// Integration-internal alerting: turns per-host health transitions and the network-tier
// diagnosis into AlertEvents (delivered via the app's notifier). Network-only alert types
// (internet loss / path down) live here, not in the generic AlertEngine.

public enum DiagnosisSensitivity: String, Codable, Sendable, CaseIterable {
    case conservative, balanced, sensitive
}

/// Per-host input for the monitor.
public struct AlertHost: Equatable, Sendable {
    public var id: String
    public var name: String
    public var status: HealthStatus
    public var notifyOnRecovery: Bool
    public var cooldown: TimeInterval

    public init(id: String, name: String, status: HealthStatus, notifyOnRecovery: Bool, cooldown: TimeInterval) {
        self.id = id
        self.name = name
        self.status = status
        self.notifyOnRecovery = notifyOnRecovery
        self.cooldown = cooldown
    }
}

public struct PingAlertMonitor: Sendable {
    public var sensitivity: DiagnosisSensitivity
    public var networkCooldown: TimeInterval
    public var pathDegradedConsecutive: Int

    private var lastStatus: [String: HealthStatus] = [:]
    private var lastSent: [String: Date] = [:]
    private var diagnosisStreak = 0
    private var lastVerdictKey: String?

    public init(sensitivity: DiagnosisSensitivity = .balanced, networkCooldown: TimeInterval = 300, pathDegradedConsecutive: Int = 3) {
        self.sensitivity = sensitivity
        self.networkCooldown = networkCooldown
        self.pathDegradedConsecutive = pathDegradedConsecutive
    }

    public mutating func evaluate(hosts: [AlertHost], diagnosis: NetworkPerspectiveDiagnosis, now: Date = Date()) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for host in hosts {
            let previous = lastStatus[host.id]
            lastStatus[host.id] = host.status
            if host.status == .down, previous != nil, previous != .down {
                if fire("hostDown:\(host.id)", cooldown: host.cooldown, now: now) {
                    events.append(AlertEvent(ruleID: "pingscope.hostDown.\(host.id)", providerID: host.id, title: "\(host.name) is down", message: "No response from \(host.name).", severity: .critical, triggeredAt: now))
                }
            } else if previous == .down, host.status == .healthy || host.status == .degraded, host.notifyOnRecovery {
                events.append(AlertEvent(ruleID: "pingscope.recovered.\(host.id)", providerID: host.id, title: "\(host.name) recovered", message: "\(host.name) is reachable again.", severity: .info, triggeredAt: now))
            }
        }
        if let event = networkAlert(diagnosis, now: now) { events.append(event) }
        return events
    }

    private mutating func networkAlert(_ diagnosis: NetworkPerspectiveDiagnosis, now: Date) -> AlertEvent? {
        guard let spec = Self.specific(diagnosis.verdict) else {
            diagnosisStreak = 0
            lastVerdictKey = nil
            return nil
        }
        let key = String(describing: diagnosis.verdict)
        if key == lastVerdictKey { diagnosisStreak += 1 } else { diagnosisStreak = 1; lastVerdictKey = key }

        let chosen: (type: String, title: String, severity: AlertSeverity)
        if case .partialDegradation = diagnosis.verdict {
            // Opt-in, streak-gated; emit the specific pathDegraded alert (not the down-verdict
            // confidence downgrade).
            guard sensitivity != .conservative, diagnosisStreak >= pathDegradedConsecutive else { return nil }
            chosen = spec
        } else if diagnosis.confidence == .high {
            chosen = spec
        } else {
            switch sensitivity {
            case .conservative: return nil
            case .balanced: chosen = ("internetLoss", "Internet problem", .warning)
            case .sensitive: chosen = spec
            }
        }
        guard fire(chosen.type, cooldown: networkCooldown, now: now) else { return nil }
        return AlertEvent(ruleID: "pingscope.\(chosen.type)", providerID: "pingscope.network", title: chosen.title, message: diagnosis.detail, severity: chosen.severity, triggeredAt: now)
    }

    private static func specific(_ verdict: NetworkPerspectiveDiagnosis.Verdict) -> (type: String, title: String, severity: AlertSeverity)? {
        switch verdict {
        case .allReachable, .noData: return nil
        case .localNetworkDown: return ("localNetworkDown", "Local network down", .critical)
        case .ispPathDown: return ("ispPathDown", "ISP path down", .critical)
        case .upstreamDown: return ("upstreamDown", "Internet unreachable", .critical)
        case .remoteServiceDown: return ("remoteServiceDown", "Remote service down", .warning)
        case .partialDegradation(let tier): return ("pathDegraded", "\(tier.displayName) degraded", .warning)
        }
    }

    private mutating func fire(_ key: String, cooldown: TimeInterval, now: Date) -> Bool {
        if let last = lastSent[key], now.timeIntervalSince(last) < cooldown { return false }
        lastSent[key] = now
        return true
    }
}
