import SwiftUI
import AmbitCore

/// Dense label/value legend for sibling component metrics.
public struct BreakdownLegendCard: View {
    public struct Model: Equatable {
        public struct Row: Identifiable, Equatable {
            public var id: String
            public var label: String
            public var value: String
            public var tone: DisplayTone

            public init(id: String, label: String, value: String, tone: DisplayTone = .neutral) {
                self.id = id
                self.label = label
                self.value = value
                self.tone = tone
            }
        }

        public var rows: [Row]

        public init(rows: [Row]) {
            self.rows = rows
        }

        public init(entityIDs: [EntityID], data: SurfaceData) {
            self.rows = entityIDs.compactMap { id in
                guard let descriptor = data.descriptors[id] else { return nil }
                let readout = data.readout(id)
                return Row(id: id.rawValue, label: descriptor.name, value: readout.text, tone: readout.tone)
            }
        }
    }

    let title: String?
    let model: Model

    public init(title: String? = nil, model: Model) {
        self.title = title
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title, !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            ForEach(model.rows) { row in
                HStack(spacing: 8) {
                    Text(row.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(row.tone.color)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
