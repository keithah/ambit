import SwiftUI

/// Switch among a multi-instance integration's instances (pingscope hosts). `selectedID == nil`
/// means the aggregate "all" view. Harvested from the pingscope host Menu.
public struct InstanceSelectorCard: View {
    public struct Option: Identifiable, Equatable {
        public var id: String
        public var label: String
        public var subtitle: String?
        public init(id: String, label: String, subtitle: String? = nil) {
            self.id = id
            self.label = label
            self.subtitle = subtitle
        }
    }
    let options: [Option]
    let selectedID: String?
    let primaryID: String?
    let onSelect: (String?) -> Void
    let onSetPrimary: ((String) -> Void)?
    let allLabel: String

    public init(
        options: [Option],
        selectedID: String?,
        primaryID: String? = nil,
        onSelect: @escaping (String?) -> Void,
        onSetPrimary: ((String) -> Void)? = nil,
        allLabel: String = "All"
    ) {
        self.options = options
        self.selectedID = selectedID
        self.primaryID = primaryID
        self.onSelect = onSelect
        self.onSetPrimary = onSetPrimary
        self.allLabel = allLabel
    }

    private var currentLabel: String {
        guard let selectedID, let match = options.first(where: { $0.id == selectedID }) else { return allLabel }
        return match.label
    }

    public var body: some View {
        Menu {
            Button(allLabel) { onSelect(nil) }
            Divider()
            ForEach(options) { option in
                Button(option.label) { onSelect(option.id) }
                if let onSetPrimary {
                    Button(option.id == primaryID ? "Primary Host" : "Set as Primary") {
                        onSetPrimary(option.id)
                    }
                    .disabled(option.id == primaryID)
                }
            }
        } label: {
            Text(currentLabel).font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
