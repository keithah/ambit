import SwiftUI
import AmbitCore

/// label + value + health dot. The universal fallback card for any entity.
public struct StatusRowCard: View {
    let title: String?
    let readout: EntityReadout
    public init(title: String?, readout: EntityReadout) {
        self.title = title
        self.readout = readout
    }
    public var body: some View {
        HStack(spacing: 8) {
            Circle().fill(readout.tone.color).frame(width: 8, height: 8)
            if let title {
                Text(title).font(.system(size: 13))
            }
            Spacer()
            Text(readout.text).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(readout.tone == .neutral ? Color.primary : readout.tone.color)
        }
        .padding(.vertical, 4)
    }
}
