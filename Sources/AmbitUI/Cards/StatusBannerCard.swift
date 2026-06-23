import SwiftUI
import AmbitCore

/// A top-level summary message bound to a summary "status" entity (P2 binds pingscope's
/// diagnosis to this). Generic — no provider-specific model.
public struct StatusBannerCard: View {
    let title: String
    let detail: String?
    let tone: DisplayTone
    let badge: String?
    public init(title: String, detail: String? = nil, tone: DisplayTone = .warn, badge: String? = nil) {
        self.title = title
        self.detail = detail
        self.tone = tone
        self.badge = badge
    }
    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let badge {
                Text(badge).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(tone.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
    }
}
