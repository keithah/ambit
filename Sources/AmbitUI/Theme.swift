import SwiftUI
import AmbitCore

// Maps the UI-free DisplayTone to concrete colors. The single place tone → color is decided,
// harvested from pingscope's PingScopeColors.tone.
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
