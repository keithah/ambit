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
    let axis: GraphAxis?
    let axisMax: Double?
    let showLegend: Bool
    let showsAxes: Bool
    let deviceClass: DeviceClass?
    let unit: String?
    let summary: [GraphSummaryItem]
    var hasDrawableSeries: Bool {
        lines.contains { line in
            line.samples.filter { $0.ok && $0.value != nil }.count > 1
        }
    }

    public init(
        title: String,
        lines: [GraphLine],
        axis: GraphAxis? = nil,
        deviceClass: DeviceClass? = nil,
        unit: String? = nil,
        summary: [GraphSummaryItem] = [],
        axisMax: Double? = nil,
        showLegend: Bool = false,
        showsAxes: Bool = false
    ) {
        self.title = title
        self.lines = lines
        self.axis = axis
        if let axis {
            self.axisMax = axis.max
        } else {
            self.axisMax = axisMax ?? GraphGeometry.niceMax(lines.flatMap { $0.samples.compactMap(\.value) })
        }
        self.showLegend = showLegend
        self.showsAxes = showsAxes
        self.deviceClass = deviceClass
        self.unit = unit
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if !title.isEmpty {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                if !showsAxes {
                    Text(axisMax.map { EntityReadout.format($0, deviceClass: deviceClass, unit: unit) } ?? "—").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: showsAxes ? 6 : 0) {
                if showsAxes {
                    GraphAxisLabels(ticks: axisTicks)
                }
                graphCanvas
                if showsAxes {
                    GraphAxisRightTicks(ticks: axisTicks)
                }
            }
            .frame(height: 112)
            .overlay {
                if !hasDrawableSeries {
                    Text("No Data")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(stride(from: 0, to: summary.count, by: 3)), id: \.self) { start in
                        HStack(spacing: 14) {
                            ForEach(summary[start..<min(start + 3, summary.count)], id: \.label) { item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    Text(item.value).font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .cardChrome()
    }

    private var resolvedAxis: GraphAxis? {
        if let axis { return axis }
        guard let axisMax else { return nil }
        return GraphAxis(min: 0, max: axisMax, unitLabel: unit, isFixed: false, isEmpty: false)
    }

    private var axisTicks: [GraphAxisTick] {
        guard let resolvedAxis else { return [] }
        let descriptor = EntityDescriptor(
            id: "graph.axis",
            instanceID: "graph",
            name: "Graph",
            kind: .sensor,
            deviceClass: deviceClass,
            unit: unit
        )
        return GraphAxisTicks.ticks(axis: resolvedAxis, descriptor: descriptor)
    }

    private var graphCanvas: some View {
        Canvas { context, size in
            drawGrid(context: context, size: size)
            guard let axisMax, axisMax > 0 else { return }
            let isMultiLine = lines.count > 1
            let plotPadding: CGFloat = showsAxes ? 6 : 0
            for (lineIndex, line) in lines.enumerated() where line.samples.count > 1 {
                let geometry = GraphGeometry.series(samples: line.samples, in: size, axisMax: axisMax, plotVerticalPadding: plotPadding)
                if let failureStyle = GraphFailureMarkStyle.style(isMultiLine: isMultiLine, isPrimaryLine: lineIndex == 0) {
                    for x in geometry.failureXPositions {
                        let endpoints = GraphGeometry.failureMarkEndpoints(x: x, in: size, plotVerticalPadding: plotPadding)
                        var failure = Path()
                        failure.move(to: endpoints.start)
                        failure.addLine(to: endpoints.end)
                        context.stroke(
                            failure,
                            with: .color(.red.opacity(failureStyle.redOpacity)),
                            lineWidth: failureStyle.lineWidth
                        )
                    }
                }
                for segment in geometry.segments where segment.count > 1 {
                    var path = Path()
                    for (index, point) in segment.enumerated() {
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(line.color), lineWidth: 1.8)
                }
            }
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        if showsAxes, let axisMax, axisMax > 0 {
            let plotTop: CGFloat = 6
            let plotHeight = max(size.height - 12, 1)
            for tick in axisTicks {
                let normalized = min(max(tick.value / axisMax, 0), 1)
                let y = plotTop + plotHeight - (plotHeight * CGFloat(normalized))
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.white.opacity(tick.value == 0 ? 0.24 : 0.14)), lineWidth: 1)
            }
        } else {
            for fraction in [0.0, 0.5, 1.0] {
                let y = size.height * (1 - fraction)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 1)
            }
        }
    }
}

private struct GraphAxisLabels: View {
    let ticks: [GraphAxisTick]

    var body: some View {
        VStack(alignment: .trailing) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                Text(tick.label)
                    .frame(height: 12, alignment: .center)
                if index != ticks.indices.last {
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.system(size: 9, weight: .regular, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: ticks.isEmpty ? 0 : 34)
    }
}

private struct GraphAxisRightTicks: View {
    let ticks: [GraphAxisTick]

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, _ in
                Rectangle()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 6, height: 1)
                if index != ticks.indices.last {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: ticks.isEmpty ? 0 : 6)
        .padding(.vertical, 6)
    }
}
