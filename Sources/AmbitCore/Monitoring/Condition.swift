import Foundation

public enum ConditionValue: Equatable, Codable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case duration(TimeInterval)
    case timestamp(Date)
    case enumeration(String)
    case missing
}

public typealias Value = ConditionValue

public enum Operand: Equatable, Codable, Sendable {
    case address(EntityID)
    case literal(ConditionValue)
}

public struct Comparison: Equatable, Codable, Sendable {
    public var lhs: Operand
    public var comparison: AlertComparison
    public var rhs: Operand

    public init(lhs: Operand, comparison: AlertComparison, rhs: Operand) {
        self.lhs = lhs
        self.comparison = comparison
        self.rhs = rhs
    }
}

public enum Edge: String, Equatable, Codable, Sendable {
    case level
    case rising
    case falling
}

public enum TemporalOp: Equatable, Codable, Sendable {
    case heldFor(TimeInterval)
    case withinWindow(TimeInterval)
    case rateOfChange(per: TimeInterval, AlertComparison, ConditionValue)
}

public struct Temporal: Equatable, Codable, Sendable {
    public var condition: Condition
    public var op: TemporalOp
    public var edge: Edge

    public init(condition: Condition, op: TemporalOp, edge: Edge) {
        self.condition = condition
        self.op = op
        self.edge = edge
    }
}

public enum ConditionPredicate: Equatable, Codable, Sendable {
    case healthTransition(to: HealthStatus)
    case diagnosisVerdict(MonitoringVerdict.Kind)
    case connectivityTransition(to: NetworkConnectivityStatus)
    case allMembersFailing(minimumCount: Int, ratio: Double)
}

public indirect enum Condition: Equatable, Codable, Sendable {
    case comparison(Comparison)
    case all([Condition])
    case any([Condition])
    case not(Condition)
    case temporal(Temporal)
    case predicate(ConditionPredicate)
}

public struct ConditionEvaluator: Sendable {
    public struct Input: Sendable {
        public var states: [EntityID: EntityState]
        public var samples: [EntityID: [Sample]]
        public var memberStatuses: [String: HealthStatus]
        public var diagnosis: MonitoringDiagnosis?
        public var connectivityStatus: NetworkConnectivityStatus?
        public var totalMemberCount: Int
        public var failingMemberCount: Int

        public init(
            states: [EntityID: EntityState] = [:],
            samples: [EntityID: [Sample]] = [:],
            memberStatuses: [String: HealthStatus] = [:],
            diagnosis: MonitoringDiagnosis? = nil,
            connectivityStatus: NetworkConnectivityStatus? = nil,
            totalMemberCount: Int = 0,
            failingMemberCount: Int = 0
        ) {
            self.states = states
            self.samples = samples
            self.memberStatuses = memberStatuses
            self.diagnosis = diagnosis
            self.connectivityStatus = connectivityStatus
            self.totalMemberCount = totalMemberCount
            self.failingMemberCount = failingMemberCount
        }
    }

    private struct TemporalState: Sendable {
        var startedAt: Date?
        var lastLevel = false
    }

    private var temporalState: [String: TemporalState] = [:]

    public init() {}

    public mutating func evaluate(_ condition: Condition, input: Input, now: Date = Date()) -> Bool {
        evaluate(condition, input: input, now: now, keyPath: "root")
    }

    public static func legacyEvaluate(_ trigger: AlertTriggerDeclaration, input: Input) -> Bool {
        switch trigger {
        case .healthTransition(let status):
            return input.memberStatuses.values.contains(status)
        case .diagnosisVerdict(let kind):
            return input.diagnosis?.verdict.kind == kind
        case .connectivityTransition(let status):
            return input.connectivityStatus == status
        case .allMembersFailing(let minimumCount, let ratio):
            guard input.totalMemberCount > 0, input.failingMemberCount >= minimumCount else { return false }
            return Double(input.failingMemberCount) / Double(input.totalMemberCount) >= ratio
        case .metricThreshold(let policy):
            guard policy.enabled,
                  let threshold = policy.threshold
            else { return false }
            return input.states.values.contains { state in
                guard case .number(let value)? = state.value else { return false }
                return threshold.comparison.matches(value, threshold: threshold.value)
            }
        }
    }

    private mutating func evaluate(_ condition: Condition, input: Input, now: Date, keyPath: String) -> Bool {
        switch condition {
        case .comparison(let comparison):
            return evaluate(comparison, input: input)
        case .all(let children):
            return children.enumerated().allSatisfy { index, child in
                evaluate(child, input: input, now: now, keyPath: "\(keyPath).all[\(index)]")
            }
        case .any(let children):
            return children.enumerated().contains { index, child in
                evaluate(child, input: input, now: now, keyPath: "\(keyPath).any[\(index)]")
            }
        case .not(let child):
            return !evaluate(child, input: input, now: now, keyPath: "\(keyPath).not")
        case .temporal(let temporal):
            return evaluate(temporal, input: input, now: now, keyPath: keyPath)
        case .predicate(let predicate):
            return Self.legacyEvaluate(predicate.triggerDeclaration, input: input)
        }
    }

    private func evaluate(_ comparison: Comparison, input: Input) -> Bool {
        let lhs = resolve(comparison.lhs, input: input)
        let rhs = resolve(comparison.rhs, input: input)
        switch (lhs, rhs) {
        case (.number(let lhs), .number(let rhs)):
            return comparison.comparison.matches(lhs, threshold: rhs)
        case (.duration(let lhs), .duration(let rhs)):
            return comparison.comparison.matches(lhs, threshold: rhs)
        case (.timestamp(let lhs), .timestamp(let rhs)):
            return comparison.comparison.matches(lhs.timeIntervalSince1970, threshold: rhs.timeIntervalSince1970)
        case (.string(let lhs), .string(let rhs)):
            return compareStrings(lhs, rhs, comparison.comparison)
        case (.enumeration(let lhs), .enumeration(let rhs)):
            return compareStrings(lhs, rhs, comparison.comparison)
        case (.bool(let lhs), .bool(let rhs)):
            return compareBools(lhs, rhs, comparison.comparison)
        case (.missing, .missing):
            return compareBools(true, true, comparison.comparison)
        default:
            return comparison.comparison == .notEqual
        }
    }

    private mutating func evaluate(_ temporal: Temporal, input: Input, now: Date, keyPath: String) -> Bool {
        let rawLevel: Bool
        switch temporal.op {
        case .heldFor(let duration):
            let child = evaluate(temporal.condition, input: input, now: now, keyPath: "\(keyPath).heldFor")
            var state = temporalState[keyPath] ?? TemporalState()
            if child {
                let started = state.startedAt ?? now
                state.startedAt = started
                rawLevel = now.timeIntervalSince(started) >= duration
            } else {
                state.startedAt = nil
                rawLevel = false
            }
            let result = edgeResult(edge: temporal.edge, level: rawLevel, previous: state.lastLevel)
            state.lastLevel = rawLevel
            temporalState[keyPath] = state
            return result
        case .withinWindow(let window):
            let level = evaluateWithinWindow(temporal.condition, input: input, now: now, window: window)
            return updateEdge(level: level, edge: temporal.edge, keyPath: keyPath)
        case .rateOfChange(let interval, let comparison, let threshold):
            let level = evaluateRateOfChange(temporal.condition, input: input, now: now, interval: interval, comparison: comparison, threshold: threshold)
            return updateEdge(level: level, edge: temporal.edge, keyPath: keyPath)
        }
    }

    private mutating func evaluateWithinWindow(_ condition: Condition, input: Input, now: Date, window: TimeInterval) -> Bool {
        condition.referencedEntityIDs.contains { id in
            let samples = (input.samples[id] ?? []).filter { now.timeIntervalSince($0.timestamp) <= window }
            return samples.contains { sample in
                var sampleInput = input
                sampleInput.states[id] = EntityState(
                    id: id,
                    value: sample.value.map(EntityValue.number),
                    availability: sample.ok && sample.value != nil ? .online : .unavailable
                )
                var evaluator = self
                return evaluator.evaluate(condition, input: sampleInput, now: sample.timestamp, keyPath: "withinWindow.sample")
            }
        }
    }

    private func evaluateRateOfChange(
        _ condition: Condition,
        input: Input,
        now: Date,
        interval: TimeInterval,
        comparison: AlertComparison,
        threshold: ConditionValue
    ) -> Bool {
        guard case .number(let thresholdValue) = threshold else { return false }
        return condition.referencedEntityIDs.contains { id in
            let samples = (input.samples[id] ?? [])
                .filter { $0.ok && $0.value != nil }
                .sorted { $0.timestamp < $1.timestamp }
            guard let first = samples.first,
                  let last = samples.last,
                  let firstValue = first.value,
                  let lastValue = last.value
            else { return false }
            let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
            guard elapsed > 0 else { return false }
            let rate = (lastValue - firstValue) / elapsed * interval
            return comparison.matches(rate, threshold: thresholdValue)
        }
    }

    private mutating func updateEdge(level: Bool, edge: Edge, keyPath: String) -> Bool {
        var state = temporalState[keyPath] ?? TemporalState()
        let result = edgeResult(edge: edge, level: level, previous: state.lastLevel)
        state.lastLevel = level
        temporalState[keyPath] = state
        return result
    }

    private func edgeResult(edge: Edge, level: Bool, previous: Bool) -> Bool {
        switch edge {
        case .level: return level
        case .rising: return level && !previous
        case .falling: return !level && previous
        }
    }

    private func resolve(_ operand: Operand, input: Input) -> ConditionValue {
        switch operand {
        case .literal(let value):
            return value
        case .address(let id):
            guard let state = input.states[id] else { return .missing }
            switch state.value {
            case .number(let value): return .number(value)
            case .bool(let value): return .bool(value)
            case .text(let value): return .string(value)
            case .table, nil: return .missing
            }
        }
    }

    private func compareStrings(_ lhs: String, _ rhs: String, _ comparison: AlertComparison) -> Bool {
        switch comparison {
        case .equal: return lhs == rhs
        case .notEqual: return lhs != rhs
        case .greaterThan: return lhs > rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        }
    }

    private func compareBools(_ lhs: Bool, _ rhs: Bool, _ comparison: AlertComparison) -> Bool {
        switch comparison {
        case .equal: return lhs == rhs
        case .notEqual: return lhs != rhs
        default: return false
        }
    }
}

public extension AlertTriggerDeclaration {
    func compile(metricEntityID: EntityID? = nil, sampleInterval: TimeInterval = 1) -> Condition {
        switch self {
        case .healthTransition(let status):
            return .predicate(.healthTransition(to: status))
        case .diagnosisVerdict(let kind):
            return .predicate(.diagnosisVerdict(kind))
        case .connectivityTransition(let status):
            return .predicate(.connectivityTransition(to: status))
        case .allMembersFailing(let minimumCount, let ratio):
            return .predicate(.allMembersFailing(minimumCount: minimumCount, ratio: ratio))
        case .metricThreshold(let policy):
            guard let metricEntityID, let threshold = policy.threshold else {
                return .comparison(Comparison(lhs: .literal(.bool(false)), comparison: .equal, rhs: .literal(.bool(true))))
            }
            let comparison = Condition.comparison(Comparison(
                lhs: .address(metricEntityID),
                comparison: threshold.comparison,
                rhs: .literal(.number(threshold.value))
            ))
            let duration = TimeInterval(max(0, policy.consecutive - 1)) * sampleInterval
            return .temporal(Temporal(condition: comparison, op: .heldFor(duration), edge: .level))
        }
    }
}

public extension AlertKindDeclaration {
    func compiledCondition(metricEntityID: EntityID? = nil, sampleInterval: TimeInterval = 1) -> Condition {
        condition ?? trigger.compile(metricEntityID: metricEntityID, sampleInterval: sampleInterval)
    }
}

private extension ConditionPredicate {
    var triggerDeclaration: AlertTriggerDeclaration {
        switch self {
        case .healthTransition(let status): return .healthTransition(to: status)
        case .diagnosisVerdict(let kind): return .diagnosisVerdict(kind)
        case .connectivityTransition(let status): return .connectivityTransition(to: status)
        case .allMembersFailing(let minimumCount, let ratio): return .allMembersFailing(minimumCount: minimumCount, ratio: ratio)
        }
    }
}

private extension Condition {
    var referencedEntityIDs: [EntityID] {
        switch self {
        case .comparison(let comparison):
            return comparison.lhs.entityIDs + comparison.rhs.entityIDs
        case .all(let conditions), .any(let conditions):
            return conditions.flatMap(\.referencedEntityIDs)
        case .not(let condition):
            return condition.referencedEntityIDs
        case .temporal(let temporal):
            return temporal.condition.referencedEntityIDs
        case .predicate:
            return []
        }
    }
}

private extension Operand {
    var entityIDs: [EntityID] {
        switch self {
        case .address(let id): return [id]
        case .literal: return []
        }
    }
}
