import SwiftUI

/// Switch among a multi-instance integration's instances (pingscope hosts). `selectedID == nil`
/// means the aggregate "all" view. Harvested from the pingscope host Menu.
public struct InstanceSelectorCard: View {
    public struct Option: Identifiable, Equatable {
        public var id: String
        public var label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }
    let options: [Option]
    let selectedID: String?
    let onSelect: (String?) -> Void
    let allLabel: String

    public init(options: [Option], selectedID: String?, onSelect: @escaping (String?) -> Void, allLabel: String = "All") {
        self.options = options
        self.selectedID = selectedID
        self.onSelect = onSelect
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
            }
        } label: {
            Text(currentLabel).font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
