import Foundation

public struct SignalPickerItem: Equatable, Identifiable, Sendable {
    public var id: EntityID
    public var title: String
    public var subtitle: String

    public init(id: EntityID, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public enum SignalPickerModel {
    public static func items(from descriptors: [EntityDescriptor]) -> [SignalPickerItem] {
        descriptors
            .filter { $0.category != .config }
            .sorted { lhs, rhs in
                if lhs.instanceID.rawValue != rhs.instanceID.rawValue {
                    return lhs.instanceID.rawValue < rhs.instanceID.rawValue
                }
                return lhs.name < rhs.name
            }
            .map { descriptor in
                SignalPickerItem(
                    id: descriptor.id,
                    title: descriptor.name,
                    subtitle: subtitle(for: descriptor)
                )
            }
    }

    private static func subtitle(for descriptor: EntityDescriptor) -> String {
        var parts = [descriptor.kind.rawValue]
        if let deviceClass = descriptor.deviceClass?.rawValue {
            parts.append(deviceClass)
        }
        if let unit = descriptor.unit {
            parts.append(unit)
        }
        return parts.joined(separator: " · ")
    }
}

public enum UserRuleBuilderValidationError: Error, Equatable, Sendable {
    case missingName
    case missingSignal
    case unknownSignal(EntityID)
    case missingReaction
}

public struct UserRuleBuilderDraft: Equatable, Sendable {
    public var displayName: String
    public var selectedSignalID: EntityID?
    public var comparison: AlertComparison
    public var comparisonValue: ConditionValue
    public var temporal: TemporalOp?
    public var edge: Edge
    public var reactions: [Reaction]
    public var enabled: Bool

    public init(
        displayName: String = "",
        selectedSignalID: EntityID? = nil,
        comparison: AlertComparison = .greaterThan,
        comparisonValue: ConditionValue = .number(0),
        temporal: TemporalOp? = nil,
        edge: Edge = .level,
        reactions: [Reaction] = [],
        enabled: Bool = true
    ) {
        self.displayName = displayName
        self.selectedSignalID = selectedSignalID
        self.comparison = comparison
        self.comparisonValue = comparisonValue
        self.temporal = temporal
        self.edge = edge
        self.reactions = reactions
        self.enabled = enabled
    }

    public func buildRule(id: UserRuleID, descriptors: [EntityDescriptor]) throws -> UserRule {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw UserRuleBuilderValidationError.missingName }
        guard let selectedSignalID else { throw UserRuleBuilderValidationError.missingSignal }
        guard descriptors.contains(where: { $0.id == selectedSignalID }) else {
            throw UserRuleBuilderValidationError.unknownSignal(selectedSignalID)
        }
        guard !reactions.isEmpty else { throw UserRuleBuilderValidationError.missingReaction }

        let comparisonCondition = Condition.comparison(Comparison(
            lhs: .address(selectedSignalID),
            comparison: comparison,
            rhs: .literal(comparisonValue)
        ))
        let condition: Condition
        if let temporal {
            condition = .temporal(Temporal(condition: comparisonCondition, op: temporal, edge: edge))
        } else {
            condition = comparisonCondition
        }
        return UserRule(
            id: id,
            displayName: trimmedName,
            condition: condition,
            reactions: reactions,
            enabled: enabled
        )
    }
}

public enum UserRuleExpressionFormatter {
    public static func string(for condition: Condition, descriptors: [EntityDescriptor]) -> String {
        let names = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0.name) })
        return format(condition, names: names)
    }

    private static func format(_ condition: Condition, names: [EntityID: String]) -> String {
        switch condition {
        case .comparison(let comparison):
            return "\(format(comparison.lhs, names: names)) \(symbol(for: comparison.comparison)) \(format(comparison.rhs, names: names))"
        case .all(let conditions):
            return conditions.map { format($0, names: names) }.joined(separator: " and ")
        case .any(let conditions):
            return conditions.map { format($0, names: names) }.joined(separator: " or ")
        case .not(let condition):
            return "not (\(format(condition, names: names)))"
        case .temporal(let temporal):
            return "\(format(temporal.condition, names: names)) \(format(temporal.op))"
        case .predicate(let predicate):
            return "\(predicate)"
        }
    }

    private static func format(_ operand: Operand, names: [EntityID: String]) -> String {
        switch operand {
        case .address(let id):
            return names[id] ?? id.rawValue
        case .literal(let value):
            return format(value)
        }
    }

    private static func format(_ value: ConditionValue) -> String {
        switch value {
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let value), .enumeration(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .duration(let value):
            return "\(Int(value))s"
        case .timestamp(let date):
            return ISO8601DateFormatter().string(from: date)
        case .missing:
            return "missing"
        }
    }

    private static func format(_ op: TemporalOp) -> String {
        switch op {
        case .heldFor(let seconds):
            return "for \(Int(seconds))s"
        case .consecutiveSamples(let count):
            return "for \(count) samples"
        case .withinWindow(let seconds):
            return "within \(Int(seconds))s"
        case .rateOfChange(let interval, let comparison, let value):
            return "rate \(symbol(for: comparison)) \(format(value)) per \(Int(interval))s"
        }
    }

    private static func symbol(for comparison: AlertComparison) -> String {
        switch comparison {
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .equal: return "=="
        case .notEqual: return "!="
        }
    }
}
