import SwiftUI
import AmbitCore

/// Rows of label/value (pingscope's TX/RX/Loss/Min/Avg/Max grid; later process & disk lists).
/// P6 adds table-valued entities; the legacy label/value initializer remains for simple grouped
/// readouts and existing callers.
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
    public struct Model: Equatable {
        public struct Column: Equatable {
            public var id: String
            public var title: String
            public var alignment: TableAlignment

            public init(id: String, title: String, alignment: TableAlignment) {
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

            public init(text: String, tone: DisplayTone = .neutral) {
                self.text = text
                self.tone = tone
            }
        }

        public var columns: [Column]
        public var rows: [RenderedRow]

        public init(columns: [Column], rows: [RenderedRow]) {
            self.columns = columns
            self.rows = rows
        }

        public init(table: TableValue) {
            self.columns = table.columns.map { Column(id: $0.id, title: $0.title, alignment: $0.alignment) }
            self.rows = table.rows.map { row in
                RenderedRow(
                    id: row.id,
                    cells: table.columns.map { column in
                        Self.cell(row.cells[column.id])
                    }
                )
            }
        }

        private static func cell(_ value: TableCellValue?) -> Cell {
            guard let value else { return Cell(text: "—") }
            switch value {
            case .text(let text):
                return Cell(text: text)
            case .number(let number, let unit):
                return Cell(text: format(number, unit: unit))
            case .badge(let text, let severity):
                return Cell(text: text, tone: tone(for: severity))
            }
        }

        private static func tone(for severity: Severity) -> DisplayTone {
            switch severity {
            case .normal: return .neutral
            case .elevated, .degraded: return .warn
            case .alerting, .down: return .bad
            }
        }

        private static func format(_ number: Double, unit: String?) -> String {
            let value = number == number.rounded() ? String(Int(number)) : String(format: "%.1f", number)
            guard let unit, !unit.isEmpty else { return value }
            if unit == "%" { return "\(value)%" }
            return "\(value) \(unit)"
        }
    }

    let title: String?
    let rows: [Row]
    let model: Model?

    public init(title: String? = nil, rows: [Row]) {
        self.title = title
        self.rows = rows
        self.model = nil
    }

    public init(title: String? = nil, table: TableValue) {
        self.title = title
        self.rows = []
        self.model = Model(table: table)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.vertical, 4)
            }
            if let model {
                tableBody(model)
            } else {
                legacyBody
            }
        }
        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
    }

    @ViewBuilder
    private func tableBody(_ model: Model) -> some View {
        HStack(spacing: 8) {
            ForEach(model.columns, id: \.id) { column in
                Text(column.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: column.alignment.swiftUIAlignment)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)

        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 8) {
                ForEach(Array(row.cells.enumerated()), id: \.offset) { cellIndex, cell in
                    let alignment = model.columns.indices.contains(cellIndex) ? model.columns[cellIndex].alignment : .leading
                    Text(cell.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(cell.tone.color)
                        .frame(maxWidth: .infinity, alignment: alignment.swiftUIAlignment)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(index.isMultiple(of: 2) ? Color.clear : Color(white: 0.11))
        }
    }

    private var legacyBody: some View {
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
