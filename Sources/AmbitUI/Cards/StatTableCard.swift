import SwiftUI

/// Rows of label/value (pingscope's TX/RX/Loss/Min/Avg/Max grid; later process & disk lists).
/// The tabular *binding* (how a group of entities maps to rows/columns) is settled in P6; this
/// view just renders the rows it is handed.
public struct StatTableCard: View {
    public struct Row: Identifiable, Equatable {
        public var id: String
        public var label: String
        public var value: String
        public init(id: String, label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }
    let title: String?
    let rows: [Row]
    public init(title: String? = nil, rows: [Row]) {
        self.title = title
        self.rows = rows
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.vertical, 4)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack {
                    Text(row.label).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.value).font(.system(size: 13, design: .monospaced))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(index.isMultiple(of: 2) ? Color.clear : Color(white: 0.11))
            }
        }
        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
    }
}
