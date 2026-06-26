import SwiftUI

/// A titled group of cards (capability- or category-grouped).
public struct SectionCard<Content: View>: View {
    let title: String?
    let content: Content
    public init(title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(.vertical, 5)
    }
}
