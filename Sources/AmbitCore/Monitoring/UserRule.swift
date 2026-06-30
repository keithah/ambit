import Foundation

public struct UserRuleID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum UserRuleSource: String, Codable, Equatable, Sendable {
    case user
}

public struct UserRule: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: UserRuleID
    public var displayName: String
    public var condition: Condition
    public var reactions: [Reaction]
    public var enabled: Bool
    public var source: UserRuleSource
    public var schemaVersion: Int
    public var cooldown: TimeInterval

    public init(
        id: UserRuleID,
        displayName: String,
        condition: Condition,
        reactions: [Reaction],
        enabled: Bool,
        source: UserRuleSource = .user,
        schemaVersion: Int = UserRule.currentSchemaVersion,
        cooldown: TimeInterval = 60
    ) {
        self.id = id
        self.displayName = displayName
        self.condition = condition
        self.reactions = reactions
        self.enabled = enabled
        self.source = source
        self.schemaVersion = schemaVersion
        self.cooldown = cooldown
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case condition
        case reactions
        case enabled
        case source
        case schemaVersion
        case cooldown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UserRuleID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        condition = try c.decode(Condition.self, forKey: .condition)
        reactions = try c.decode([Reaction].self, forKey: .reactions)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source = try c.decodeIfPresent(UserRuleSource.self, forKey: .source) ?? .user
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        cooldown = try c.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? 60
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(condition, forKey: .condition)
        try c.encode(reactions, forKey: .reactions)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(source, forKey: .source)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(cooldown, forKey: .cooldown)
    }

    public var hasNonNotifyReaction: Bool {
        reactions.contains { reaction in
            if case .notify = reaction { return false }
            return true
        }
    }
}

public struct UserRuleDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var rules: [UserRule]

    public init(schemaVersion: Int = UserRule.currentSchemaVersion, rules: [UserRule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules.map(Self.migrate)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let decodedRules = try c.decodeIfPresent([UserRule].self, forKey: .rules) ?? []
        schemaVersion = UserRule.currentSchemaVersion
        rules = decodedRules.map(Self.migrate)
        if decodedVersion > UserRule.currentSchemaVersion {
            rules = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(rules, forKey: .rules)
    }

    private static func migrate(_ rule: UserRule) -> UserRule {
        var migrated = rule
        migrated.schemaVersion = UserRule.currentSchemaVersion
        migrated.source = .user
        return migrated
    }
}

public protocol UserRuleStore: Sendable {
    func load() -> [UserRule]
    func save(_ rules: [UserRule])
    func create(_ rule: UserRule)
    func update(_ rule: UserRule)
    func delete(id: UserRuleID)
    func reorder(ids: [UserRuleID])
}

public extension UserRuleStore {
    func create(_ rule: UserRule) {
        var rules = load().filter { $0.id != rule.id }
        rules.append(rule)
        save(rules)
    }

    func update(_ rule: UserRule) {
        var rules = load()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        save(rules)
    }

    func delete(id: UserRuleID) {
        save(load().filter { $0.id != id })
    }

    func reorder(ids: [UserRuleID]) {
        let rules = load()
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var reordered = ids.compactMap { byID[$0] }
        let known = Set(ids)
        reordered += rules.filter { !known.contains($0.id) }
        save(reordered)
    }
}

public struct UserDefaultsUserRuleStore: UserRuleStore, @unchecked Sendable {
    public static let defaultKey = "userRules"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [UserRule] {
        guard let data = defaults.data(forKey: key),
              let document = try? JSONDecoder().decode(UserRuleDocument.self, from: data)
        else { return [] }
        return document.rules
    }

    public func save(_ rules: [UserRule]) {
        let document = UserRuleDocument(rules: rules)
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum UserRuleSettingsPane: Sendable {
    case notifications
    case automations
}

public enum UserRulePlacement {
    public static func rules(_ rules: [UserRule], for pane: UserRuleSettingsPane) -> [UserRule] {
        switch pane {
        case .notifications:
            return rules
        case .automations:
            return rules.filter(\.hasNonNotifyReaction)
        }
    }
}

public struct UserRuleRunResult: Equatable, Sendable {
    public var ruleID: UserRuleID
    public var reaction: Reaction
    public var executionResult: ReactionExecutionResult

    public init(ruleID: UserRuleID, reaction: Reaction, executionResult: ReactionExecutionResult) {
        self.ruleID = ruleID
        self.reaction = reaction
        self.executionResult = executionResult
    }
}

public struct UserRuleRunner: Sendable {
    private var evaluators: [UserRuleID: ConditionEvaluator] = [:]
    private var activeRuleIDs: Set<UserRuleID> = []
    private var deliveredBoundNotificationKeys: Set<String> = []
    private var mutationState = SurfaceMutationState()
    private var firingState = AlertFiringState()

    public init() {}

    public mutating func evaluate(
        rules: [UserRule],
        input: ConditionEvaluator.Input,
        now: Date = Date(),
        executor: ReactionExecutor,
        confirmation: ReactionConfirmation = .notRequired
    ) async throws -> [UserRuleRunResult] {
        var results: [UserRuleRunResult] = []
        for rule in rules where rule.enabled {
            var evaluator = evaluators[rule.id] ?? ConditionEvaluator()
            let isActive = evaluator.evaluate(rule.condition, input: input, now: now)
            evaluators[rule.id] = evaluator
            let wasActive = activeRuleIDs.contains(rule.id)
            if isActive {
                guard !wasActive else { continue }
                activeRuleIDs.insert(rule.id)
                for (index, reaction) in rule.reactions.enumerated() {
                    let reactionKey = "\(rule.id.rawValue):\(index)"
                    switch reaction {
                    case .notify(let spec):
                        guard firingState.fire(reactionKey, cooldown: rule.cooldown, now: now) else { continue }
                        let executionResult = try await executor.execute(reaction, confirmation: confirmation)
                        if spec.lifecycle == .boundToCondition {
                            deliveredBoundNotificationKeys.insert(reactionKey)
                        }
                        results.append(UserRuleRunResult(ruleID: rule.id, reaction: reaction, executionResult: executionResult))
                    case .mutateSurface(let mutation):
                        mutationState.apply(mutation, isActive: true)
                        let executionResult = try await executor.execute(reaction, confirmation: confirmation)
                        results.append(UserRuleRunResult(ruleID: rule.id, reaction: reaction, executionResult: executionResult))
                    case .runCommand:
                        guard firingState.fire(reactionKey, cooldown: rule.cooldown, now: now) else { continue }
                        let executionResult = try await executor.execute(reaction, confirmation: confirmation)
                        results.append(UserRuleRunResult(ruleID: rule.id, reaction: reaction, executionResult: executionResult))
                    case .applyContext:
                        let executionResult = try await executor.execute(reaction, confirmation: confirmation)
                        results.append(UserRuleRunResult(ruleID: rule.id, reaction: reaction, executionResult: executionResult))
                    }
                }
            } else if wasActive {
                activeRuleIDs.remove(rule.id)
                for (index, reaction) in rule.reactions.enumerated() {
                    let reactionKey = "\(rule.id.rawValue):\(index)"
                    switch reaction {
                    case .notify(let spec) where spec.lifecycle == .boundToCondition && deliveredBoundNotificationKeys.remove(reactionKey) != nil:
                        results.append(UserRuleRunResult(
                            ruleID: rule.id,
                            reaction: reaction,
                            executionResult: .notificationCleared(spec)
                        ))
                    case .mutateSurface(let mutation):
                        mutationState.apply(mutation, isActive: false)
                        results.append(UserRuleRunResult(
                            ruleID: rule.id,
                            reaction: reaction,
                            executionResult: .revertedSurface(mutation)
                        ))
                    case .applyContext(let id, _):
                        results.append(UserRuleRunResult(
                            ruleID: rule.id,
                            reaction: .applyContext(id: id, active: false),
                            executionResult: .contextDeferred(id)
                        ))
                    default:
                        break
                    }
                }
            }
        }
        return results
    }

    public func surfaceValue(for address: SurfacePropertyAddress) -> ConditionValue? {
        mutationState.value(for: address)
    }
}
