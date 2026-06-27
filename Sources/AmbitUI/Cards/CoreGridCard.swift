import SwiftUI
import AmbitCore

/// Compact grid of homogeneous per-core/per-channel measurements.
public struct CoreGridCard: View {
    public struct Model: Equatable {
        public struct Cell: Identifiable, Equatable {
            public var id: String
            public var label: String
            public var readout: String
            public var fraction: Double?
            public var tone: DisplayTone
            public var isUnavailable: Bool

            public init(id: String, label: String, readout: String, fraction: Double?, tone: DisplayTone, isUnavailable: Bool) {
                self.id = id
                self.label = label
                self.readout = readout
                self.fraction = fraction
                self.tone = tone
                self.isUnavailable = isUnavailable
            }
        }

        public var cells: [Cell]

        public init(cells: [Cell]) {
            self.cells = cells
        }

        public init(entityIDs: [EntityID], data: SurfaceData) {
            self.cells = entityIDs.compactMap { id in
                guard let descriptor = data.descriptors[id] else { return nil }
                let state = data.states[id]
                let readout = data.readout(id)
                return Cell(
                    id: id.rawValue,
                    label: descriptor.name,
                    readout: readout.text,
                    fraction: readout.fraction,
                    tone: readout.tone,
                    isUnavailable: state?.availability == .unavailable
                )
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
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 7)], spacing: 8) {
                ForEach(model.cells) { cell in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 5)
                                .fill(cell.tone.color.opacity(cell.isUnavailable ? 0.18 : 0.85))
                                .frame(height: 30 * CGFloat(cell.fraction ?? 0))
                        }
                        .frame(height: 30)
                        Text(cell.label).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                        Text(cell.readout).font(.system(size: 9.5, design: .monospaced)).lineLimit(1)
                    }
                }
            }
        }
        .cardChrome()
    }
}
