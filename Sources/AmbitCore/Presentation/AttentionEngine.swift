import Foundation

// The Attention engine (presentation-model.md §4): the generic, surface-agnostic Core service that
// turns the enriched entity set + the firing-alert set + the user's visibility/priority config into
// a per-surface ORDERED selection with reasons. A CONSUMER of HealthState/AlertEngine/EntityEnricher,
// not a new detector.
//
// P4.3 builds the pure selection — visibility → tier → ranking → capacity/overflow. The sustained-
// samples debounce + transition boost (presentation-model.md §4e) arrive in P4.4; evaluate() is
// `mutating` from the start so that state lands without an API change.

public struct SurfaceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum OverflowPolicy: Equatable, Sendable, Codable { case countBadge, rotate, drop }

/// Per-surface lane budget. Menu-bar slot = 1 in P4; Dynamic Island = 1 (+rotate); Watch tiny.
public struct SurfaceCapacity: Equatable, Sendable {
    public var lanes: Int
    public var overflow: OverflowPolicy
    public init(lanes: Int, overflow: OverflowPolicy = .countBadge) {
        self.lanes = lanes
        self.overflow = overflow
    }
}

/// Escalation tier, resting → interrupting.
public enum AttentionTier: Int, Sendable, Codable, Comparable {
    case detail, surfaced, alerted
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Why an entity reached a lane — debugging aid and on-thesis (deterministic, inspectable).
public struct AttentionReason: Equatable, Sendable {
    public var summary: String
    public var tier: AttentionTier
    public var severity: Severity
    public var score: Int
    public var transitionBoosted: Bool
    public init(summary: String, tier: AttentionTier, severity: Severity, score: Int, transitionBoosted: Bool = false) {
        self.summary = summary
        self.tier = tier
        self.severity = severity
        self.score = score
        self.transitionBoosted = transitionBoosted
    }
}

public struct SurfacedEntity: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var tier: AttentionTier
    public var score: Int
    public var reason: AttentionReason
    public init(id: EntityID, tier: AttentionTier, score: Int, reason: AttentionReason) {
        self.id = id
        self.tier = tier
        self.score = score
        self.reason = reason
    }
}

public struct AttentionSelection: Equatable, Sendable {
    public var lanes: [SurfacedEntity]    // length ≤ capacity.lanes, descending score; renderers read this
    public var overflowCount: Int         // surfaced-but-didn't-fit (drives "+N"); 0 when all fit
    public var alerted: [SurfacedEntity]  // tier == .alerted (notification-eligible / red rendering)
    public init(lanes: [SurfacedEntity] = [], overflowCount: Int = 0, alerted: [SurfacedEntity] = []) {
        self.lanes = lanes
        self.overflowCount = overflowCount
        self.alerted = alerted
    }
}

public struct AttentionCandidate: Equatable, Sendable {
    public var descriptor: EntityDescriptor
    public var state: EntityState         // ENRICHED (post-EntityEnricher: staleness + health severity)
    public init(descriptor: EntityDescriptor, state: EntityState) {
        self.descriptor = descriptor
        self.state = state
    }
}

public struct AttentionEngine {
    public init() {}

    /// Stateless in P4.3 (the debounce/transition state lands in P4.4). `surfaces` maps a SurfaceID
    /// to its capacity; `alertingIDs` are entities the AlertEngine is currently firing on.
    public mutating func evaluate(
        candidates: [AttentionCandidate],
        surfaces: [SurfaceID: SurfaceCapacity],
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date
    ) -> [SurfaceID: AttentionSelection] {
        let evaluated = candidates.map { resolve($0, alertingIDs: alertingIDs, config: config) }
        var result: [SurfaceID: AttentionSelection] = [:]
        for (surfaceID, capacity) in surfaces {
            result[surfaceID] = select(evaluated, capacity: capacity)
        }
        return result
    }

    // MARK: Per-entity resolution

    private struct Evaluated {
        var id: EntityID
        var isPrimary: Bool
        var priority: Int
        var visibility: GlanceVisibility
        var severity: Severity            // effective (folds in alert tier for ranking)
        var score: Int
        var tier: AttentionTier
        var thresholdCrossed: Bool
        // Disjoint lane groups (an entity belongs to exactly one): alerted > reserved > surfaced.
        var isAlerted: Bool
        var isReserved: Bool
        var isSurfaced: Bool
        var reasonSummary: String
    }

    private func resolve(_ candidate: AttentionCandidate, alertingIDs: Set<EntityID>, config: PresentationConfig) -> Evaluated {
        let d = candidate.descriptor
        let override = config.entityOverrides[d.id]
        let visibility = override?.visibility ?? d.defaultVisibility
        let pinned = override?.pinned ?? false
        let priority = d.priority ?? 0
        let threshold = override?.displayThreshold ?? d.displayThreshold

        // The display+health severity, reusing EntityEnricher's threshold rule over the ALREADY-final
        // availability — no re-run of staleness. Stale/offline data is not escalated by the display
        // threshold (stale-suppression preserved).
        let baseSeverity = candidate.state.severity ?? .normal
        let thresholdCrossed = candidate.state.availability == .online
            && EntityEnricher.displaySeverity(value: candidate.state.value, threshold: threshold) >= .elevated
        let displaySeverity: Severity = (candidate.state.availability == .online)
            ? Swift.max(baseSeverity, EntityEnricher.displaySeverity(value: candidate.state.value, threshold: threshold))
            : baseSeverity

        let isAlerted = alertingIDs.contains(d.id) && visibility != .never
        let isReserved = !isAlerted && (visibility == .always || pinned) && visibility != .never
        let autoSurfaced = !isAlerted && !isReserved && visibility == .auto && displaySeverity >= .elevated

        let tier: AttentionTier = isAlerted ? .alerted : ((isReserved || autoSurfaced) ? .surfaced : .detail)
        // Alerting outranks everything below it even when display+health stayed lower.
        let effectiveSeverity = Swift.max(displaySeverity, isAlerted ? .alerting : .normal)
        let score = effectiveSeverity.rawValue * 1000 + clampedPriority(priority)

        let summary = reasonSummary(id: d.id, tier: tier, severity: effectiveSeverity,
                                    score: score, priority: priority, thresholdCrossed: thresholdCrossed,
                                    reserved: isReserved)

        return Evaluated(
            id: d.id, isPrimary: d.isPrimary, priority: priority, visibility: visibility,
            severity: effectiveSeverity, score: score, tier: tier, thresholdCrossed: thresholdCrossed,
            isAlerted: isAlerted, isReserved: isReserved, isSurfaced: autoSurfaced, reasonSummary: summary
        )
    }

    // MARK: Per-surface selection

    private func select(_ all: [Evaluated], capacity: SurfaceCapacity) -> AttentionSelection {
        // Lane-fill order (capacity-tight): alerted preempts reserved preempts surfaced; descending
        // score within each, stable EntityID tie-break.
        let alerted = all.filter(\.isAlerted).sorted(by: order)
        let reserved = all.filter(\.isReserved).sorted(by: order)
        let surfaced = all.filter(\.isSurfaced).sorted(by: order)

        var lanes: [SurfacedEntity] = []
        for group in [alerted, reserved, surfaced] {
            for e in group where lanes.count < capacity.lanes {
                lanes.append(surfacedEntity(e))
            }
        }

        let wanting = alerted.count + reserved.count + surfaced.count   // groups are disjoint
        let overflowCount = Swift.max(0, wanting - capacity.lanes)

        // Resting fallback: nothing wanted a lane → show the calm primary so the bar is never empty.
        if lanes.isEmpty, capacity.lanes > 0, let rest = restingFallback(all) {
            lanes.append(rest)
        }

        return AttentionSelection(lanes: lanes, overflowCount: overflowCount, alerted: alerted.map(surfacedEntity))
    }

    private func restingFallback(_ all: [Evaluated]) -> SurfacedEntity? {
        let shown = all.filter { $0.visibility != .never }
        guard !shown.isEmpty else { return nil }
        let primaries = shown.filter(\.isPrimary)
        let pool = primaries.isEmpty ? shown : primaries
        guard let pick = pool.sorted(by: restingOrder).first else { return nil }
        let reason = AttentionReason(
            summary: "resting: \(pick.id.rawValue) (nothing elevated), priority \(pick.priority)",
            tier: .detail, severity: pick.severity, score: pick.score
        )
        return SurfacedEntity(id: pick.id, tier: .detail, score: pick.score, reason: reason)
    }

    // MARK: Helpers

    private func surfacedEntity(_ e: Evaluated) -> SurfacedEntity {
        SurfacedEntity(
            id: e.id, tier: e.tier, score: e.score,
            reason: AttentionReason(summary: e.reasonSummary, tier: e.tier, severity: e.severity, score: e.score)
        )
    }

    private func order(_ a: Evaluated, _ b: Evaluated) -> Bool {
        a.score != b.score ? a.score > b.score : a.id.rawValue < b.id.rawValue
    }

    private func restingOrder(_ a: Evaluated, _ b: Evaluated) -> Bool {
        a.priority != b.priority ? a.priority > b.priority : a.id.rawValue < b.id.rawValue
    }

    private func clampedPriority(_ p: Int) -> Int { Swift.min(Swift.max(p, 0), 999) }

    private func reasonSummary(id: EntityID, tier: AttentionTier, severity: Severity, score: Int,
                               priority: Int, thresholdCrossed: Bool, reserved: Bool) -> String {
        var parts = ["\(id.rawValue) \(tier): severity \(severity), priority \(priority), score \(score)"]
        if reserved { parts.append("reserved lane") }
        if thresholdCrossed { parts.append("display threshold crossed") }
        return parts.joined(separator: ", ")
    }
}
