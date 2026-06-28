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
    private var deliveredNetworkAlert = false

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
                    events.append(AlertEvent(
                        ruleID: "ping.hostDown.\(host.id)",
                        providerID: host.id,
                        target: .entity(Self.latencyEntityID(for: host.id)),
                        title: "\(host.name) is down",
                        message: "No response from \(host.name).",
                        severity: .critical,
                        triggeredAt: now
                    ))
                }
            } else if previous == .down, host.status == .healthy || host.status == .degraded, host.notifyOnRecovery {
                events.append(AlertEvent(
                    ruleID: "ping.recovered.\(host.id)",
                    providerID: host.id,
                    target: .entity(Self.latencyEntityID(for: host.id)),
                    phase: .recovered,
                    title: "\(host.name) recovered",
                    message: "\(host.name) is reachable again.",
                    severity: .info,
                    triggeredAt: now
                ))
            }
        }
        if let event = internetLossSafetyNet(hosts: hosts, now: now) {
            events.append(event)
        } else if let event = networkAlert(diagnosis, now: now) {
            events.append(event)
        }
        return events
    }

    private mutating func networkAlert(_ diagnosis: NetworkPerspectiveDiagnosis, now: Date) -> AlertEvent? {
        guard let spec = Self.specific(diagnosis.verdict) else {
            diagnosisStreak = 0
            lastVerdictKey = nil
            if deliveredNetworkAlert, diagnosis.verdict == .allReachable {
                deliveredNetworkAlert = false
                return AlertEvent(
                    ruleID: "ping.pathRecovered",
                    providerID: "ping.network",
                    target: .entity(DiagnosisEntity.entityID),
                    phase: .recovered,
                    title: "Network path recovered",
                    message: "The monitored network path is reachable again.",
                    severity: .info,
                    triggeredAt: now
                )
            }
            return nil
        }
        let key = String(describing: diagnosis.verdict)
        if key == lastVerdictKey { diagnosisStreak += 1 } else { diagnosisStreak = 1; lastVerdictKey = key }

        let chosen: (type: String, title: String, severity: Severity)
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
        deliveredNetworkAlert = true
        return AlertEvent(
            ruleID: "ping.\(chosen.type)",
            providerID: "ping.network",
            target: .entity(DiagnosisEntity.entityID),
            title: chosen.title,
            message: diagnosis.detail,
            severity: chosen.severity,
            triggeredAt: now
        )
    }

    private mutating func internetLossSafetyNet(hosts: [AlertHost], now: Date) -> AlertEvent? {
        guard hosts.count >= 2,
              hosts.allSatisfy({ $0.status == .down }),
              fire("internetLoss", cooldown: networkCooldown, now: now)
        else { return nil }
        deliveredNetworkAlert = true
        return AlertEvent(
            ruleID: "ping.internetLoss",
            providerID: "ping.network",
            target: .entity(DiagnosisEntity.entityID),
            title: "Internet problem",
            message: "\(hosts.count)/\(hosts.count) monitored hosts are unreachable.",
            severity: .warning,
            triggeredAt: now
        )
    }

    private static func latencyEntityID(for hostID: String) -> EntityID {
        EntityID(rawValue: "\(hostID)/probe.latency_ms")
    }

    private static func specific(_ verdict: NetworkPerspectiveDiagnosis.Verdict) -> (type: String, title: String, severity: Severity)? {
        switch verdict {
        case .allReachable, .noData, .monitoringStalled: return nil   // stalled monitoring is not an outage — never alert
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

public struct NetworkStatusAlertMonitor: Sendable {
    public var cooldown: TimeInterval
    private var lastSent: [String: Date] = [:]

    public init(cooldown: TimeInterval = 300) {
        self.cooldown = cooldown
    }

    public mutating func evaluate(
        previous: NetworkConnectivityStatus,
        current: NetworkConnectivityStatus,
        now: Date = Date()
    ) -> AlertEvent? {
        guard previous != current else { return nil }
        if current == .connected {
            return AlertEvent(
                ruleID: "network.status.recovered",
                providerID: "network.path",
                target: .entity(DiagnosisEntity.entityID),
                phase: .recovered,
                title: "Network path recovered",
                message: "The system network path is connected again.",
                severity: .info,
                triggeredAt: now
            )
        }
        let key = "networkStatus:\(current.rawValue)"
        guard fire(key, now: now) else { return nil }
        return AlertEvent(
            ruleID: "network.status.\(current.rawValue)",
            providerID: "network.path",
            target: .entity(DiagnosisEntity.entityID),
            title: title(for: current),
            message: message(for: current),
            severity: current == .noInternet ? .warning : .critical,
            triggeredAt: now
        )
    }

    private mutating func fire(_ key: String, now: Date) -> Bool {
        if let last = lastSent[key], now.timeIntervalSince(last) < cooldown { return false }
        lastSent[key] = now
        return true
    }

    private func title(for status: NetworkConnectivityStatus) -> String {
        switch status {
        case .connected: return "Network connected"
        case .noInternet: return "No internet"
        case .noIPAddress, .notConnected: return "Local network down"
        }
    }

    private func message(for status: NetworkConnectivityStatus) -> String {
        switch status {
        case .connected: return "The system network path is connected."
        case .noInternet: return "The system reports no internet connection."
        case .noIPAddress: return "The network link has no usable IP address."
        case .notConnected: return "No network link."
        }
    }
}
