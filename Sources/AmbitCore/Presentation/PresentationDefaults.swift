import Foundation

// Presentation defaults an integration declares on its EntityDescriptors and the generic
// layer reads (all overridable by the user via PresentationConfig). presentation-model.md §6.

/// Whether an entity appears on glance surfaces (menu bar, Island, …). `auto` = conditional
/// on health / alert / display-threshold; resolved by the Attention engine (P4).
public enum GlanceVisibility: String, Sendable, Codable { case always, auto, never }

/// How a single sensor visualizes on the detail surface.
public enum GraphStyle: String, Sendable, Codable { case sparkline, gauge, progress, none }

/// The default time window a history graph shows. Windows harvested from pingscope's TimeRange.
public enum GraphRange: String, Sendable, Codable, CaseIterable {
    case m1, m5, m10, h1

    public var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m5: return 300
        case .m10: return 600
        case .h1: return 3600
        }
    }

    public var label: String {
        switch self {
        case .m1: return "1m"
        case .m5: return "5m"
        case .m10: return "10m"
        case .h1: return "1h"
        }
    }
}

/// The "surface" tier condition — distinct from the alert threshold (presentation-model.md §4a).
/// Reuses the existing AlertComparison so display + alert thresholds speak one comparison vocabulary.
public struct DisplayThreshold: Equatable, Sendable, Codable {
    public var comparison: AlertComparison
    public var value: Double
    public var consecutive: Int   // sustained-samples debounce, mirrors the M4 pattern

    public init(comparison: AlertComparison, value: Double, consecutive: Int = 1) {
        self.comparison = comparison
        self.value = value
        self.consecutive = consecutive
    }
}

/// Generic display tone for a value/row. UI-free; AmbitUI maps it to a Color (Theme.swift).
public enum DisplayTone: String, Sendable, Codable { case neutral, good, warn, bad }
