import SwiftUI
import AmbitCore

/// A top-level summary message bound to a summary "status" entity (P2 binds pingscope's
/// diagnosis to this). Generic — no provider-specific model.
public struct StatusBannerCard: View {
    @Environment(\.statusStylePalette) private var statusStylePalette
    public struct Model: Equatable {
        public var title: String?
        public var detail: String?
        public var tone: DisplayTone
        public var badge: String?
        public var isCompactReason: Bool

        public init(title: String?, detail: String? = nil, tone: DisplayTone = .warn, badge: String? = nil, isCompactReason: Bool = false) {
            self.title = title
            self.detail = detail
            self.tone = tone
            self.badge = badge
            self.isCompactReason = isCompactReason
        }

        public var iconName: String {
            switch tone {
            case .good: return "checkmark.circle.fill"
            case .neutral: return "info.circle.fill"
            case .warn, .bad: return "exclamationmark.triangle.fill"
            }
        }

        public var primaryLine: String? {
            guard isCompactReason else { return title }
            switch (title, detail) {
            case let (.some(title), .some(detail)) where !detail.isEmpty:
                return "\(title) · \(detail)"
            case let (.some(title), _):
                return title
            case (_, let .some(detail)):
                return detail
            case (.none, .none):
                return nil
            }
        }

        public var detailLine: String? {
            isCompactReason ? nil : detail
        }

        public var verticalPadding: CGFloat {
            isCompactReason ? 7 : 10
        }
    }

    let title: String?
    let detail: String?
    let tone: DisplayTone
    let badge: String?
    let isCompactReason: Bool
    private var model: Model {
        Model(title: title, detail: detail, tone: tone, badge: badge, isCompactReason: isCompactReason)
    }

    public init(title: String?, detail: String? = nil, tone: DisplayTone = .warn, badge: String? = nil, isCompactReason: Bool = false) {
        self.title = title
        self.detail = detail
        self.tone = tone
        self.badge = badge
        self.isCompactReason = isCompactReason
    }
    public var body: some View {
        let model = model
        HStack(spacing: 9) {
            Image(systemName: model.iconName).foregroundStyle(tone.color(using: statusStylePalette))
            VStack(alignment: .leading, spacing: 1) {
                if let title = model.primaryLine {
                    Text(title)
                        .font(.system(size: model.isCompactReason ? 11.5 : 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let detail = model.detailLine {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let badge = model.badge {
                Text(badge).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, model.verticalPadding)
        .background(tone.color(using: statusStylePalette).opacity(model.isCompactReason ? 0.10 : 0.13), in: RoundedRectangle(cornerRadius: 8))
    }
}
