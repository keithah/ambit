import SwiftUI
import AmbitCore

public struct GraphLine: Identifiable, Equatable {
    public var id: String
    public var color: Color
    public var samples: [Sample]
    public init(id: String, color: Color, samples: [Sample]) {
        self.id = id
        self.color = color
        self.samples = samples
    }
}

/// Sparkline / multi-line history graph. Generic replacement for pingscope's LatencyGraph;
/// all geometry comes from GraphGeometry so this view is a thin Canvas wrapper.
public struct HistoryGraphCard: View {
    let title: String
    let lines: [GraphLine]
    let axisMax: Double
    let showLegend: Bool
    let deviceClass: DeviceClass?
    let unit: String?
    let summary: [GraphSummaryItem]

    public init(title: String, lines: [GraphLine], deviceClass: DeviceClass? = nil, unit: String? = nil, summary: [GraphSummaryItem] = [], axisMax: Double? = nil, showLegend: Bool = false) {
        self.title = title
        self.lines = lines
        self.axisMax = axisMax ?? GraphGeometry.niceMax(lines.flatMap { $0.samples.compactMap(\.value) })
        self.showLegend = showLegend
        self.deviceClass = deviceClass
        self.unit = unit
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !title.isEmpty {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Text(EntityReadout.format(axisMax, deviceClass: deviceClass, unit: unit)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                for fraction in [0.0, 0.5, 1.0] {
                    let y = size.height * (1 - fraction)
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 1)
                }
                for line in lines where line.samples.count > 1 {
                    let pts = GraphGeometry.points(samples: line.samples, in: size, axisMax: axisMax)
                    var path = Path()
                    for (index, point) in pts.enumerated() {
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(line.color), lineWidth: 1.5)
                }
            }
            .frame(height: 130)
            if showLegend {
                HStack(spacing: 12) {
                    ForEach(lines) { line in
                        HStack(spacing: 5) {
                            Circle().fill(line.color).frame(width: 8, height: 8)
                            Text(line.id).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !summary.isEmpty {
                HStack(spacing: 18) {
                    ForEach(summary, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(item.value).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
