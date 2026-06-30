import Foundation

public struct MonitoringAlertMember: Equatable, Sendable {
    public var id: String
    public var name: String
    public var status: HealthStatus
    public var target: AlertTarget
    public var notifyOnRecovery: Bool
    public var cooldown: TimeInterval

    public init(
        id: String,
        name: String,
        status: HealthStatus,
        target: AlertTarget,
        notifyOnRecovery: Bool,
        cooldown: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.target = target
        self.notifyOnRecovery = notifyOnRecovery
        self.cooldown = cooldown
    }
}

public struct MonitoringNetworkChange: Equatable, Sendable {
    public var previousGateway: String?
    public var currentGateway: String?

    public init(previousGateway: String?, currentGateway: String?) {
        self.previousGateway = previousGateway
        self.currentGateway = currentGateway
    }
}

public struct MonitoringAlertStateMachine: Sendable {
    public var declarations: [AlertKindDeclaration]
    public var sensitivity: DiagnosisSensitivity
    public var networkCooldown: TimeInterval
    public var pathDegradedConsecutive: Int
    public var networkAwarenessConfig: NetworkAwarenessConfig
    public var warmUpCycles: Int
    public var alertKindOverrides: [AlertKindID: AlertKindOverride]
    public var entityAlertKindOverrides: [EntityID: [AlertKindID: AlertKindOverride]]

    private var lastStatus: [String: HealthStatus] = [:]
    private var firingState = AlertFiringState()
    private var diagnosisStreak = 0
    private var lastVerdictKey: String?
    private var deliveredNetworkAlert = false
    private var deliveredNetworkStatusAlert = false
    private var deliveredHostDownIDs: Set<String> = []
    private var warmUpEvaluations = 0
    private var pendingHostDownIDs: Set<String> = []
    private var conditionEvaluators: [AlertKindID: ConditionEvaluator] = [:]

    public init(
        declarations: [AlertKindDeclaration] = [],
        sensitivity: DiagnosisSensitivity = .balanced,
        networkCooldown: TimeInterval = 300,
        pathDegradedConsecutive: Int = 3,
        networkAwarenessConfig: NetworkAwarenessConfig = NetworkAwarenessConfig(),
        alertKindOverrides: [AlertKindID: AlertKindOverride] = [:],
        entityAlertKindOverrides: [EntityID: [AlertKindID: AlertKindOverride]] = [:],
        warmUpCycles: Int? = nil
    ) {
        self.declarations = declarations
        self.sensitivity = sensitivity
        self.networkCooldown = networkCooldown
        self.pathDegradedConsecutive = pathDegradedConsecutive
        self.networkAwarenessConfig = networkAwarenessConfig
        self.alertKindOverrides = alertKindOverrides
        self.entityAlertKindOverrides = entityAlertKindOverrides
        self.warmUpCycles = warmUpCycles ?? networkAwarenessConfig.warmUpCycles
    }

    public mutating func evaluate(
        members: [MonitoringAlertMember],
        diagnosis: MonitoringDiagnosis,
        now: Date = Date()
    ) -> [AlertEvent] {
        let warmingUp = isWarmingUp
        defer { completeWarmUpEvaluation() }
        var hostEvents: [AlertEvent] = []
        for member in members {
            let declaration = hostDownDeclaration
            let previous = lastStatus[member.id]
            lastStatus[member.id] = member.status
            if member.status == .down, previous == nil {
                pendingHostDownIDs.insert(member.id)
            } else if member.status == .down, previous != .down {
                pendingHostDownIDs.insert(member.id)
                if isEnabled(declaration, target: member.target),
                   conditionMatches(declaration, member: member, members: members, diagnosis: diagnosis, now: now),
                   !warmingUp,
                   fire("hostDown:\(member.id)", cooldown: member.cooldown, now: now) {
                    hostEvents.append(hostDownEvent(member, now: now))
                    deliveredHostDownIDs.insert(member.id)
                    pendingHostDownIDs.remove(member.id)
                }
            } else if member.status == .down,
                      pendingHostDownIDs.contains(member.id),
                      isEnabled(declaration, target: member.target),
                      conditionMatches(declaration, member: member, members: members, diagnosis: diagnosis, now: now),
                      !warmingUp,
                      fire("hostDown:\(member.id)", cooldown: member.cooldown, now: now) {
                hostEvents.append(hostDownEvent(member, now: now))
                deliveredHostDownIDs.insert(member.id)
                pendingHostDownIDs.remove(member.id)
            } else if previous == .down,
                      (member.status == .healthy || member.status == .degraded),
                      isEnabled(declaration, target: member.target),
                      member.notifyOnRecovery,
                      deliveredHostDownIDs.contains(member.id) {
                _ = conditionMatches(declaration, member: member, members: members, diagnosis: diagnosis, now: now)
                hostEvents.append(hostRecoveredEvent(member, now: now))
                deliveredHostDownIDs.remove(member.id)
                pendingHostDownIDs.remove(member.id)
            } else if member.status != .down {
                pendingHostDownIDs.remove(member.id)
            }
        }
        if !warmingUp, let event = internetLossSafetyNet(members: members, now: now) {
            for member in members {
                deliveredHostDownIDs.remove(member.id)
            }
            return [event]
        }
        var events = hostEvents
        if !warmingUp, let event = networkAlert(diagnosis, members: members, now: now) {
            events.append(event)
        } else if warmingUp {
            trackNetworkAlertState(diagnosis)
        }
        return events
    }

    public mutating func evaluateNetworkStatus(
        previous: NetworkConnectivityStatus,
        current: NetworkConnectivityStatus,
        now: Date = Date()
    ) -> AlertEvent? {
        guard networkAwarenessConfig.connectivityAlertsEnabled, previous != current else { return nil }
        guard !isWarmingUp else { return nil }
        if current == .connected {
            guard deliveredNetworkStatusAlert else { return nil }
            deliveredNetworkStatusAlert = false
            return AlertEvent(
                ruleID: "network.status.recovered",
                providerID: "network.path",
                target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                phase: .recovered,
                title: "Network path recovered",
                message: "The system network path is connected again.",
                severity: .info,
                triggeredAt: now
            )
        }
        let key = "networkStatus:\(current.rawValue)"
        guard fire(key, cooldown: networkAwarenessConfig.cooldown, now: now) else { return nil }
        deliveredNetworkStatusAlert = true
        return AlertEvent(
            ruleID: "network.status.\(current.rawValue)",
            providerID: "network.path",
            target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
            title: networkStatusTitle(for: current),
            message: networkStatusMessage(for: current),
            severity: current == .noInternet ? .warning : .critical,
            triggeredAt: now
        )
    }

    public mutating func networkChangeEvent(_ change: MonitoringNetworkChange, now: Date = Date()) -> AlertEvent? {
        guard networkAwarenessConfig.networkChangeAlertsEnabled,
              let previousGateway = change.previousGateway,
              let currentGateway = change.currentGateway,
              previousGateway != currentGateway
        else { return nil }
        guard !isWarmingUp else { return nil }
        return AlertEvent(
            ruleID: "network.gateway.changed",
            providerID: "network.path",
            target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
            title: "Network changed",
            message: "Gateway changed from \(previousGateway) to \(currentGateway).",
            severity: .info,
            triggeredAt: now
        )
    }

    public mutating func resetWarmUp() {
        warmUpEvaluations = 0
    }

    private func hostDownEvent(_ member: MonitoringAlertMember, now: Date) -> AlertEvent {
        let declaration = hostDownDeclaration
        return AlertEvent(
            ruleID: "\(declaration.id.rawValue).\(member.id)",
            providerID: member.id,
            target: member.target,
            title: AlertTemplateRenderer.render(declaration.titleTemplate, context: AlertTemplateContext(hostName: member.name)),
            message: AlertTemplateRenderer.render(declaration.messageTemplate, context: AlertTemplateContext(hostName: member.name)),
            severity: declaration.severity,
            triggeredAt: now
        )
    }

    private func hostRecoveredEvent(_ member: MonitoringAlertMember, now: Date) -> AlertEvent {
        let declaration = hostDownDeclaration
        let recovery = declaration.recovery
        return AlertEvent(
            ruleID: recoveryRuleID(for: declaration, memberID: member.id),
            providerID: member.id,
            target: member.target,
            phase: .recovered,
            title: AlertTemplateRenderer.render(recovery?.titleTemplate ?? "{hostName} recovered", context: AlertTemplateContext(hostName: member.name)),
            message: AlertTemplateRenderer.render(recovery?.messageTemplate ?? "{hostName} is reachable again.", context: AlertTemplateContext(hostName: member.name)),
            severity: .info,
            triggeredAt: now
        )
    }

    private var hostDownDeclaration: AlertKindDeclaration {
        declarations.first {
            if case .healthTransition(to: .down) = $0.trigger { return true }
            return false
        } ?? AlertKindDeclaration(
            id: "ping.hostDown",
            titleTemplate: "{hostName} is down",
            messageTemplate: "No response from {hostName}.",
            severity: .critical,
            defaultEnabled: true,
            target: .providerMetric(providerID: "ping", metricID: "latency_ms"),
            trigger: .healthTransition(to: .down),
            recovery: AlertRecoveryDeclaration(
                titleTemplate: "{hostName} recovered",
                messageTemplate: "{hostName} is reachable again."
            ),
            cooldown: 60
        )
    }

    private func recoveryRuleID(for declaration: AlertKindDeclaration, memberID: String) -> String {
        declaration.id.rawValue == "ping.hostDown"
            ? "ping.recovered.\(memberID)"
            : "\(declaration.id.rawValue).recovered.\(memberID)"
    }

    private func isEnabled(_ declaration: AlertKindDeclaration, target: AlertTarget?) -> Bool {
        if let entityID = target?.entityID,
           let enabled = entityAlertKindOverrides[entityID]?[declaration.id]?.enabled {
            return enabled
        }
        if let enabled = alertKindOverrides[declaration.id]?.enabled {
            return enabled
        }
        return declaration.defaultEnabled
    }

    private mutating func networkAlert(_ diagnosis: MonitoringDiagnosis, members: [MonitoringAlertMember], now: Date) -> AlertEvent? {
        guard let spec = networkSpec(for: diagnosis) else {
            diagnosisStreak = 0
            lastVerdictKey = nil
            if deliveredNetworkAlert, diagnosis.verdict.kind == .allReachable {
                deliveredNetworkAlert = false
                return AlertEvent(
                    ruleID: "ping.pathRecovered",
                    providerID: "ping.network",
                    target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
                    phase: .recovered,
                    title: "Network path recovered",
                    message: "The monitored network path is reachable again.",
                    severity: .info,
                    triggeredAt: now
                )
            }
            return nil
        }
        if let declaration = diagnosisDeclaration(for: diagnosis.verdict.kind),
           !conditionMatches(declaration, members: members, diagnosis: diagnosis, now: now) {
            return nil
        }

        let key = verdictKey(diagnosis.verdict)
        if key == lastVerdictKey {
            diagnosisStreak += 1
        } else {
            diagnosisStreak = 1
            lastVerdictKey = key
        }

        let chosen: (type: String, title: String, severity: Severity)
        if diagnosis.verdict.kind == .partialDegradation {
            guard sensitivity != .conservative, diagnosisStreak >= pathDegradedConsecutive else { return nil }
            chosen = spec
        } else if diagnosis.confidence == .high {
            chosen = spec
        } else {
            switch sensitivity {
            case .conservative:
                return nil
            case .balanced:
                chosen = ("internetLoss", "Internet problem", .warning)
            case .sensitive:
                chosen = spec
            }
        }
        guard fire(chosen.type, cooldown: networkCooldown, now: now) else { return nil }
        deliveredNetworkAlert = true
        return AlertEvent(
            ruleID: "ping.\(chosen.type)",
            providerID: "ping.network",
            target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
            title: chosen.title,
            message: networkAlertMessage(for: diagnosis, members: members),
            severity: chosen.severity,
            triggeredAt: now
        )
    }

    private mutating func trackNetworkAlertState(_ diagnosis: MonitoringDiagnosis) {
        guard networkSpec(for: diagnosis) != nil else {
            if diagnosis.verdict.kind == .allReachable {
                diagnosisStreak = 0
                lastVerdictKey = nil
            }
            return
        }
        let key = verdictKey(diagnosis.verdict)
        if key == lastVerdictKey {
            diagnosisStreak += 1
        } else {
            diagnosisStreak = 1
            lastVerdictKey = key
        }
    }

    private func networkSpec(for diagnosis: MonitoringDiagnosis) -> (type: String, title: String, severity: Severity)? {
        switch diagnosis.verdict.kind {
        case .allReachable, .noData, .monitoringStalled:
            return nil
        case .localNetworkDown:
            return ("localNetworkDown", "Local network down", .critical)
        case .accessNetworkDown:
            return ("ispPathDown", "ISP path down", .critical)
        case .upstreamDown:
            return ("upstreamDown", "Internet unreachable", .critical)
        case .remoteServiceDown:
            return ("remoteServiceDown", "Remote service down", .warning)
        case .partialDegradation:
            return ("pathDegraded", "\(diagnosis.verdict.affectedRole?.displayName ?? "Path") degraded", .warning)
        }
    }

    private func networkAlertMessage(for diagnosis: MonitoringDiagnosis, members: [MonitoringAlertMember]) -> String {
        guard diagnosis.verdict.kind == .remoteServiceDown else { return diagnosis.detail }
        let namesByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) })
        let names = diagnosis.affectedEntityIDs.map { namesByID[$0.rawValue] ?? $0.rawValue }
        guard !names.isEmpty else { return diagnosis.detail }
        let visible = Array(names.prefix(2))
        let extra = names.count - visible.count
        if extra > 0 {
            return "No response from \(visible.joined(separator: ", ")), +\(extra) more \(extra == 1 ? "host" : "hosts")."
        }
        return "No response from \(visible.joined(separator: ", "))."
    }

    private mutating func internetLossSafetyNet(members: [MonitoringAlertMember], now: Date) -> AlertEvent? {
        let declaration = declarations.first {
            if case .allMembersFailing = $0.trigger { return true }
            return false
        }
        guard members.count >= 2,
              members.allSatisfy({ $0.status == .down }),
              declaration.map({ conditionMatches($0, members: members, diagnosis: nil, now: now) }) ?? true,
              fire("internetLoss", cooldown: networkCooldown, now: now)
        else { return nil }
        deliveredNetworkAlert = true
        return AlertEvent(
            ruleID: "ping.internetLoss",
            providerID: "ping.network",
            target: .entity(DiagnosticSummaryEntity.Owner.ping.entityID),
            title: "Internet problem",
            message: "\(members.count)/\(members.count) monitored hosts are unreachable.",
            severity: .warning,
            triggeredAt: now
        )
    }

    private func verdictKey(_ verdict: MonitoringVerdict) -> String {
        switch verdict.kind {
        case .noData: return "noData"
        case .monitoringStalled: return "monitoringStalled"
        case .allReachable: return "allReachable"
        case .localNetworkDown: return "localNetworkDown"
        case .accessNetworkDown: return "ispPathDown"
        case .upstreamDown: return "upstreamDown"
        case .remoteServiceDown: return "remoteServiceDown(hostIDs: [])"
        case .partialDegradation:
            return "partialDegradation(tier: \(legacyTierName(for: verdict.affectedRole)))"
        }
    }

    private func legacyTierName(for role: MonitoringRole?) -> String {
        switch role {
        case .localGateway, .localLink: return "localGateway"
        case .accessNetwork: return "ispEdge"
        case .upstreamInternet: return "upstream"
        case .remoteService, .endpoint: return "remoteService"
        case nil: return "upstream"
        }
    }

    private mutating func fire(_ key: String, cooldown: TimeInterval, now: Date) -> Bool {
        firingState.fire(key, cooldown: cooldown, now: now)
    }

    private mutating func conditionMatches(
        _ declaration: AlertKindDeclaration,
        member: MonitoringAlertMember? = nil,
        members: [MonitoringAlertMember],
        diagnosis: MonitoringDiagnosis?,
        now: Date
    ) -> Bool {
        let condition = declaration.compiledCondition()
        let input = conditionInput(member: member, members: members, diagnosis: diagnosis)
        var evaluator = conditionEvaluators[declaration.id] ?? ConditionEvaluator()
        let result = evaluator.evaluate(condition, input: input, now: now)
        conditionEvaluators[declaration.id] = evaluator
        return result
    }

    private func conditionInput(
        member: MonitoringAlertMember?,
        members: [MonitoringAlertMember],
        diagnosis: MonitoringDiagnosis?
    ) -> ConditionEvaluator.Input {
        var statuses = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.status) })
        if let member {
            statuses[member.id] = member.status
        }
        let totalCount = statuses.isEmpty && member != nil ? 1 : statuses.count
        let failingCount = statuses.values.filter { $0 == .down }.count
        return ConditionEvaluator.Input(
            memberStatuses: statuses,
            diagnosis: diagnosis,
            totalMemberCount: totalCount,
            failingMemberCount: failingCount
        )
    }

    private func diagnosisDeclaration(for kind: MonitoringVerdict.Kind) -> AlertKindDeclaration? {
        declarations.first {
            if case .diagnosisVerdict(let declaredKind) = $0.trigger {
                return declaredKind == kind
            }
            return false
        }
    }

    private var isWarmingUp: Bool {
        warmUpEvaluations < max(0, warmUpCycles)
    }

    private mutating func completeWarmUpEvaluation() {
        if isWarmingUp {
            warmUpEvaluations += 1
        }
    }

    private func networkStatusTitle(for status: NetworkConnectivityStatus) -> String {
        switch status {
        case .connected: return "Network connected"
        case .noInternet: return "No internet"
        case .noIPAddress, .notConnected: return "Local network down"
        }
    }

    private func networkStatusMessage(for status: NetworkConnectivityStatus) -> String {
        switch status {
        case .connected: return "The system network path is connected."
        case .noInternet: return "The system reports no internet connection."
        case .noIPAddress: return "The network link has no usable IP address."
        case .notConnected: return "No network link."
        }
    }
}
