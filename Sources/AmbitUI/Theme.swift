import SwiftUI
import AmbitCore

// Maps the UI-free DisplayTone to concrete colors. The single place tone → color is decided,
// harvested from pingscope's PingColors.tone.
public extension DisplayTone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .warn: return Color(red: 0.90, green: 0.70, blue: 0.29)
        case .bad: return Color(red: 1.0, green: 0.32, blue: 0.28)
        }
    }
}

/// Deterministic per-line colors for multi-series graphs (harvested from pingscope's palette).
public enum Theme {
    public static let linePalette: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.96),  // blue
        Color(red: 0.20, green: 0.78, blue: 0.35),  // green
        Color(red: 1.00, green: 0.62, blue: 0.26),  // orange
        Color(red: 0.69, green: 0.45, blue: 0.95),  // purple
        Color(red: 0.30, green: 0.78, blue: 0.85)   // teal
    ]
    public static func lineColor(_ index: Int) -> Color { linePalette[index % linePalette.count] }
}
