import SwiftUI
import AmbitCore

/// A bounded value as a ring/donut. Uses SwiftUI Gauge on macOS 13.
public struct GaugeCard: View {
    @Environment(\.statusStylePalette) private var statusStylePalette
    let title: String?
    let readout: EntityReadout
    public init(title: String?, readout: EntityReadout) {
        self.title = title
        self.readout = readout
    }
    public var body: some View {
        VStack(spacing: 6) {
            Gauge(value: readout.fraction ?? 0) {
                EmptyView()
            } currentValueLabel: {
                Text(readout.text).font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(readout.tone.color(using: statusStylePalette))
            if let title {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .cardChrome()
    }
}
