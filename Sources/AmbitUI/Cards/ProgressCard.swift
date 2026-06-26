import SwiftUI
import AmbitCore

/// A bounded value as a linear bar (battery, percent).
public struct ProgressCard: View {
    let title: String?
    let readout: EntityReadout
    public init(title: String?, readout: EntityReadout) {
        self.title = title
        self.readout = readout
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let title {
                    Text(title).font(.system(size: 13))
                }
                Spacer()
                Text(readout.text).font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            ProgressView(value: readout.fraction ?? 0)
                .tint(readout.tone.color)
        }
        .padding(.vertical, 4)
    }
}
