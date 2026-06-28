import SwiftUI
import AmbitCore

public struct SampleHistoryCard: View {
    public struct Model: Equatable {
        public struct Column: Equatable {
            public var id: String
            public var title: String
            public var alignment: TableAlignment

            public init(id: String, title: String, alignment: TableAlignment = .leading) {
                self.id = id
                self.title = title
                self.alignment = alignment
            }
        }

        public struct RenderedRow: Identifiable, Equatable {
            public var id: String
            public var cells: [Cell]

            public init(id: String, cells: [Cell]) {
                self.id = id
                self.cells = cells
            }
        }

        public struct Cell: Equatable {
            public var text: String
            public var tone: DisplayTone
            public var isSingleLine: Bool

            public init(text: String, tone: DisplayTone = .neutral, isSingleLine: Bool = true) {
                self.text = text
                self.tone = tone
                self.isSingleLine = isSingleLine
            }
        }

        public var columns: [Column]
        public var rows: [RenderedRow]
        public var emptyMessage: String
        public static let defaultRowLimit = 8
        public static let rowVerticalPadding: CGFloat = 4
        public static let headerVerticalPadding: CGFloat = 5
        public static let rowFontSize: CGFloat = 11.5

        public init(rows: [SampleHistoryRow], emptyMessage: String = "No samples yet.") {
            self.columns = [
                Column(id: "time", title: "Time"),
                Column(id: "result", title: "Result"),
                Column(id: "status", title: "Status")
            ]
            self.rows = rows.map { row in
                RenderedRow(id: "\(row.timestamp.timeIntervalSince1970)", cells: [
                    Cell(text: Self.timeText(row.timestamp)),
                    Cell(text: row.result, tone: row.isFailure ? .bad : .neutral),
                    Cell(text: row.status)
                ])
            }
            self.emptyMessage = emptyMessage
        }

        public static func timeText(_ timestamp: Date) -> String {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter.string(from: timestamp)
        }
    }

    let title: String?
    let model: Model

    public init(title: String? = nil, model: Model) {
        self.title = title
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.vertical, 4)
            }
            tableHeader
            if model.rows.isEmpty {
                Text(model.emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { cellIndex, cell in
                            let alignment = model.columns.indices.contains(cellIndex) ? model.columns[cellIndex].alignment : .leading
                            Text(cell.text)
                                .font(.system(size: Model.rowFontSize, design: .monospaced))
                                .foregroundStyle(cell.tone.color)
                                .lineLimit(cell.isSingleLine ? 1 : nil)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: alignment.swiftUIAlignment)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, Model.rowVerticalPadding)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.035))
                }
            }
        }
        .cardChrome()
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            ForEach(model.columns, id: \.id) { column in
                Text(column.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: column.alignment.swiftUIAlignment)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, Model.headerVerticalPadding)
    }
}

private extension TableAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
