import Foundation

public struct ContextID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum ContextManualOverride: String, Codable, Equatable, Sendable {
    case auto
    case pinnedActive
    case pinnedInactive
}

public struct ContextOverlay: Codable, Equatable, Sendable {
    public var entityOverrides: [EntityID: EntityPresentationOverride]
    public var integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride]
    public var slotOverrides: [SlotID: SlotPresentationOverride]
    public var alertKindOverrides: [AlertKindID: AlertKindOverride]
    public var entityAlertKindOverrides: [EntityID: [AlertKindID: AlertKindOverride]]

    /// Rule toggles are engine-level overlays rather than PresentationConfig fields.
    public var ruleToggles: [UserRuleID: Bool]

    public init(
        entityOverrides: [EntityID: EntityPresentationOverride] = [:],
        integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride] = [:],
        slotOverrides: [SlotID: SlotPresentationOverride] = [:],
        alertKindOverrides: [AlertKindID: AlertKindOverride] = [:],
        entityAlertKindOverrides: [EntityID: [AlertKindID: AlertKindOverride]] = [:],
        ruleToggles: [UserRuleID: Bool] = [:]
    ) {
        self.entityOverrides = entityOverrides
        self.integrationOverrides = integrationOverrides
        self.slotOverrides = slotOverrides
        self.alertKindOverrides = alertKindOverrides
        self.entityAlertKindOverrides = entityAlertKindOverrides
        self.ruleToggles = ruleToggles
    }
}

public struct ContextDeclaration: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: ContextID
    public var displayName: String
    public var icon: String?
    public var condition: Condition
    public var priority: Int
    public var manualOverride: ContextManualOverride
    public var overlay: ContextOverlay
    public var schemaVersion: Int

    public init(
        id: ContextID,
        displayName: String,
        icon: String? = nil,
        condition: Condition,
        priority: Int,
        manualOverride: ContextManualOverride = .auto,
        overlay: ContextOverlay = ContextOverlay(),
        schemaVersion: Int = ContextDeclaration.currentSchemaVersion
    ) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.condition = condition
        self.priority = priority
        self.manualOverride = manualOverride
        self.overlay = overlay
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, icon, condition, priority, manualOverride, overlay, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ContextID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        condition = try c.decode(Condition.self, forKey: .condition)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        manualOverride = try c.decodeIfPresent(ContextManualOverride.self, forKey: .manualOverride) ?? .auto
        overlay = try c.decodeIfPresent(ContextOverlay.self, forKey: .overlay) ?? ContextOverlay()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    }
}

public enum ContextActiveEntity {
    public static func id(for contextID: ContextID) -> EntityID {
        EntityID(rawValue: "context:\(contextID.rawValue)#active")
    }

    public static func descriptor(for context: ContextDeclaration) -> EntityDescriptor {
        EntityDescriptor(
            id: id(for: context.id),
            instanceID: ProviderInstanceID(rawValue: "context/\(context.id.rawValue)"),
            name: "\(context.displayName) active",
            kind: .binarySensor,
            deviceClass: nil,
            capability: "context.active",
            stateClass: nil
        )
    }

    public static func state(for contextID: ContextID, active: Bool) -> EntityState {
        EntityState(
            id: id(for: contextID),
            value: .bool(active),
            availability: .online,
            severity: active ? .normal : nil
        )
    }
}

public enum ContextTraceSource: Codable, Equatable, Hashable, Sendable {
    case base
    case context(ContextID)
}

public enum ContextTraceAddress: Codable, Equatable, Hashable, Sendable {
    case entity(EntityID)
    case integration(IntegrationInstanceID)
    case slot(SlotID)
    case alertKind(AlertKindID)
    case entityAlertKind(EntityID, AlertKindID)
}

public struct ContextTraceLayer: Codable, Equatable, Sendable {
    public var source: ContextTraceSource
    public var priority: Int?
    public var contextName: String?

    public init(source: ContextTraceSource, priority: Int? = nil, contextName: String? = nil) {
        self.source = source
        self.priority = priority
        self.contextName = contextName
    }
}

public struct ContextResolutionTrace: Codable, Equatable, Sendable {
    public var address: ContextTraceAddress
    public var layers: [ContextTraceLayer]

    public init(address: ContextTraceAddress, layers: [ContextTraceLayer]) {
        self.address = address
        self.layers = layers
    }

    public var winningSource: ContextTraceSource? {
        layers.last?.source
    }
}

public struct ContextResolution: Equatable, Sendable {
    public var config: PresentationConfig
    public var traces: [ContextTraceAddress: ContextResolutionTrace]

    public init(config: PresentationConfig, traces: [ContextTraceAddress: ContextResolutionTrace]) {
        self.config = config
        self.traces = traces
    }
}

public enum ContextResolver {
    public static func resolve(base: PresentationConfig, activeContexts: [ContextDeclaration]) -> ContextResolution {
        guard !activeContexts.isEmpty else {
            return ContextResolution(config: base, traces: [:])
        }

        var config = base
        var traces: [ContextTraceAddress: ContextResolutionTrace] = [:]
        let ordered = activeContexts.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id.rawValue < $1.id.rawValue
        }

        for context in ordered {
            let layer = ContextTraceLayer(source: .context(context.id), priority: context.priority, contextName: context.displayName)
            for (id, value) in context.overlay.entityOverrides {
                let address = ContextTraceAddress.entity(id)
                appendBaseIfNeeded(address, traces: &traces, existsInBase: base.entityOverrides[id] != nil)
                traces[address]?.layers.append(layer)
                config.entityOverrides[id] = value
            }
            for (id, value) in context.overlay.integrationOverrides {
                let address = ContextTraceAddress.integration(id)
                appendBaseIfNeeded(address, traces: &traces, existsInBase: base.integrationOverrides[id] != nil)
                traces[address]?.layers.append(layer)
                config.integrationOverrides[id] = value
            }
            for (id, value) in context.overlay.slotOverrides {
                let address = ContextTraceAddress.slot(id)
                appendBaseIfNeeded(address, traces: &traces, existsInBase: base.slotOverrides[id] != nil)
                traces[address]?.layers.append(layer)
                config.slotOverrides[id] = value
            }
            for (id, value) in context.overlay.alertKindOverrides {
                let address = ContextTraceAddress.alertKind(id)
                appendBaseIfNeeded(address, traces: &traces, existsInBase: base.alertKindOverrides[id] != nil)
                traces[address]?.layers.append(layer)
                config.alertKindOverrides[id] = value
            }
            for (entityID, overrides) in context.overlay.entityAlertKindOverrides {
                for (kindID, value) in overrides {
                    let address = ContextTraceAddress.entityAlertKind(entityID, kindID)
                    appendBaseIfNeeded(address, traces: &traces, existsInBase: base.entityAlertKindOverrides[entityID]?[kindID] != nil)
                    traces[address]?.layers.append(layer)
                    var entityOverrides = config.entityAlertKindOverrides[entityID] ?? [:]
                    entityOverrides[kindID] = value
                    config.entityAlertKindOverrides[entityID] = entityOverrides
                }
            }
        }

        return ContextResolution(config: config, traces: traces)
    }

    private static func appendBaseIfNeeded(
        _ address: ContextTraceAddress,
        traces: inout [ContextTraceAddress: ContextResolutionTrace],
        existsInBase: Bool
    ) {
        guard traces[address] == nil else { return }
        var layers: [ContextTraceLayer] = []
        if existsInBase {
            layers.append(ContextTraceLayer(source: .base))
        }
        traces[address] = ContextResolutionTrace(address: address, layers: layers)
    }
}

public struct ContextEvaluation: Equatable, Sendable {
    public var activeIDs: [ContextID]
    public var activeContexts: [ContextDeclaration]
    public var states: [EntityID: EntityState]

    public init(activeIDs: [ContextID], activeContexts: [ContextDeclaration], states: [EntityID: EntityState]) {
        self.activeIDs = activeIDs
        self.activeContexts = activeContexts
        self.states = states
    }
}

public struct ContextStateMachine: Sendable {
    private var evaluators: [ContextID: ConditionEvaluator] = [:]
    private var appliedOverrides: [ContextID: Bool] = [:]
    private var lastActiveIDs: Set<ContextID> = []
    private let dwell: TimeInterval

    public init(dwell: TimeInterval = 15) {
        self.dwell = dwell
    }

    public mutating func apply(_ results: [UserRuleRunResult]) {
        for result in results {
            switch result.executionResult {
            case .contextApplied(let id, let active):
                appliedOverrides[ContextID(rawValue: id)] = active
            default:
                break
            }
        }
    }

    public mutating func setContext(_ id: ContextID, active: Bool?) {
        appliedOverrides[id] = active
        if let active {
            if active {
                lastActiveIDs.insert(id)
            } else {
                lastActiveIDs.remove(id)
            }
        }
    }

    public func currentEvaluation(contexts: [ContextDeclaration]) -> ContextEvaluation {
        materialize(contexts: contexts) { context in
            if let override = appliedOverrides[context.id] { return override }
            return lastActiveIDs.contains(context.id)
        }
    }

    public mutating func evaluate(
        contexts: [ContextDeclaration],
        input: ConditionEvaluator.Input,
        now: Date = Date()
    ) -> ContextEvaluation {
        var evaluatedActiveIDs = Set<ContextID>()
        for context in contexts.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let isActive: Bool
            if let override = appliedOverrides[context.id] {
                isActive = override
            } else {
                switch context.manualOverride {
                case .pinnedActive:
                    isActive = true
                case .pinnedInactive:
                    isActive = false
                case .auto:
                    var evaluator = evaluators[context.id] ?? ConditionEvaluator()
                    let wrapped = context.condition.dwellWrappedIfNeeded(dwell)
                    isActive = evaluator.evaluate(wrapped, input: input, now: now)
                    evaluators[context.id] = evaluator
                }
            }
            if isActive {
                evaluatedActiveIDs.insert(context.id)
            }
        }
        lastActiveIDs = evaluatedActiveIDs
        return currentEvaluation(contexts: contexts)
    }

    private func materialize(
        contexts: [ContextDeclaration],
        isActive: (ContextDeclaration) -> Bool
    ) -> ContextEvaluation {
        var active: [ContextDeclaration] = []
        var states: [EntityID: EntityState] = [:]
        for context in contexts {
            let activeState = isActive(context)
            if activeState {
                active.append(context)
            }
            states[ContextActiveEntity.id(for: context.id)] = ContextActiveEntity.state(for: context.id, active: activeState)
        }
        active.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id.rawValue < $1.id.rawValue
        }
        return ContextEvaluation(activeIDs: active.map(\.id), activeContexts: active, states: states)
    }
}

private extension Condition {
    func dwellWrappedIfNeeded(_ dwell: TimeInterval) -> Condition {
        if case .temporal = self {
            return self
        }
        return .temporal(Temporal(condition: self, op: .heldFor(dwell), edge: .level))
    }
}

public struct ContextCycleDiagnostic: Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public struct ContextValidationResult: Equatable, Sendable {
    public var contexts: [ContextDeclaration]
    public var rules: [UserRule]
    public var diagnostics: [ContextCycleDiagnostic]

    public init(contexts: [ContextDeclaration], rules: [UserRule], diagnostics: [ContextCycleDiagnostic]) {
        self.contexts = contexts
        self.rules = rules
        self.diagnostics = diagnostics
    }
}

public enum ContextCycleDetector {
    public static func validate(contexts: [ContextDeclaration], rules: [UserRule]) -> ContextValidationResult {
        let contextsByID = Dictionary(uniqueKeysWithValues: contexts.map { ($0.id, $0) })
        var sanitizedRules = rules
        var diagnostics: [ContextCycleDiagnostic] = []

        for index in sanitizedRules.indices {
            let rule = sanitizedRules[index]
            guard rule.enabled else { continue }
            for contextID in rule.appliedContextIDs {
                guard let context = contextsByID[contextID],
                      context.overlay.ruleToggles[rule.id] != nil
                else { continue }
                sanitizedRules[index].enabled = false
                diagnostics.append(ContextCycleDiagnostic(
                    message: "Disabled \(rule.id.rawValue) because it forms a context cycle through \(context.id.rawValue)."
                ))
                break
            }
        }

        return ContextValidationResult(contexts: contexts, rules: sanitizedRules, diagnostics: diagnostics)
    }
}

private extension UserRule {
    var appliedContextIDs: [ContextID] {
        reactions.compactMap { reaction in
            guard case .applyContext(let id, _) = reaction else { return nil }
            return ContextID(rawValue: id)
        }
    }
}

public struct ContextDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var contexts: [ContextDeclaration]

    public init(schemaVersion: Int = ContextDeclaration.currentSchemaVersion, contexts: [ContextDeclaration]) {
        self.schemaVersion = ContextDeclaration.currentSchemaVersion
        self.contexts = contexts.map(Self.migrate)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, contexts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let decodedContexts = try c.decodeIfPresent([ContextDeclaration].self, forKey: .contexts) ?? []
        schemaVersion = ContextDeclaration.currentSchemaVersion
        contexts = decodedVersion > ContextDeclaration.currentSchemaVersion ? [] : decodedContexts.map(Self.migrate)
    }

    private static func migrate(_ context: ContextDeclaration) -> ContextDeclaration {
        var migrated = context
        migrated.schemaVersion = ContextDeclaration.currentSchemaVersion
        return migrated
    }
}

public protocol ContextStore: Sendable {
    func load() -> [ContextDeclaration]
    func save(_ contexts: [ContextDeclaration])
    func create(_ context: ContextDeclaration)
    func update(_ context: ContextDeclaration)
    func delete(id: ContextID)
    func reorder(ids: [ContextID])
}

public extension ContextStore {
    func create(_ context: ContextDeclaration) {
        var contexts = load().filter { $0.id != context.id }
        contexts.append(context)
        save(contexts)
    }

    func update(_ context: ContextDeclaration) {
        var contexts = load()
        if let index = contexts.firstIndex(where: { $0.id == context.id }) {
            contexts[index] = context
        } else {
            contexts.append(context)
        }
        save(contexts)
    }

    func delete(id: ContextID) {
        save(load().filter { $0.id != id })
    }

    func reorder(ids: [ContextID]) {
        let contexts = load()
        let byID = Dictionary(uniqueKeysWithValues: contexts.map { ($0.id, $0) })
        var reordered = ids.enumerated().compactMap { index, id -> ContextDeclaration? in
            guard var context = byID[id] else { return nil }
            context.priority = index
            return context
        }
        let known = Set(ids)
        reordered += contexts.filter { !known.contains($0.id) }
        save(reordered)
    }
}

public struct UserDefaultsContextStore: ContextStore, @unchecked Sendable {
    public static let defaultKey = "contexts"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [ContextDeclaration] {
        guard let data = defaults.data(forKey: key),
              let document = try? JSONDecoder().decode(ContextDocument.self, from: data)
        else { return [] }
        return document.contexts
    }

    public func save(_ contexts: [ContextDeclaration]) {
        let document = ContextDocument(contexts: contexts)
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: key)
    }
}
