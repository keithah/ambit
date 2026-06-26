import AmbitCore
import AmbitUI
import SwiftUI

private enum SettingsSelection: Hashable {
    case integration(IntegrationInstanceID)
    case slots
}

struct AmbitSettings: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var selection: SettingsSelection = .slots

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 820, height: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ambit").font(.system(size: 18, weight: .bold))
                Text("Settings").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)

            VStack(spacing: 2) {
                ForEach(viewModel.presentationSettings.integrations) { group in
                    sidebarButton(
                        title: group.displayName,
                        subtitle: group.integrationID.rawValue,
                        systemImage: "shippingbox",
                        selection: .integration(group.id)
                    )
                }
                Divider().padding(.vertical, 6)
                sidebarButton(
                    title: "Slots",
                    subtitle: "\(viewModel.presentationSettings.slots.count) configured",
                    systemImage: "menubar.rectangle",
                    selection: .slots
                )
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarButton(
        title: String,
        subtitle: String,
        systemImage: String,
        selection item: SettingsSelection
    ) -> some View {
        Button { selection = item } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(selection == item ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selection == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(selection == item ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .integration(let id):
            if let group = viewModel.presentationSettings.integrations.first(where: { $0.id == id }) {
                IntegrationSettingsDetail(group: group)
            } else {
                EmptySettingsDetail(title: "Integration", message: "Select an integration.")
            }
        case .slots:
            SlotsSettingsDetail(slots: viewModel.presentationSettings.slots)
        }
    }
}

private struct IntegrationSettingsDetail: View {
    let group: IntegrationSettingsGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                entityList
            }
            .padding(22)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.displayName).font(.system(size: 22, weight: .bold))
                Spacer()
                Text(group.enabled ? "Enabled" : "Disabled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(group.enabled ? .green : .secondary)
            }
            Text(group.integrationID.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var entityList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Entities")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            if group.entities.isEmpty {
                Text("No entities available.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(group.entities) { row in
                    EntitySettingsRowView(row: row)
                    if row.id != group.entities.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

private struct EntitySettingsRowView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let row: EntitySettingsRow

    private var readout: EntityReadout {
        EntityReadout.make(descriptor: row.descriptor, state: row.state)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.descriptor.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(row.descriptor.id.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 3) {
                Text(readout.text)
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    Text(row.effectiveVisibility.rawValue.capitalized)
                    Text(row.state?.availability.rawValue.capitalized ?? "No Data")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                controls
            }
        }
        .padding(.vertical, 10)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Visibility", selection: visibilitySelection) {
                ForEach(EntityVisibilityChoice.allCases) { choice in
                    Text(choice.title(defaultVisibility: row.descriptor.defaultVisibility)).tag(choice)
                }
            }
            .labelsHidden()
            .frame(width: 145)

            Toggle("Pin", isOn: pinned)
                .toggleStyle(.checkbox)

            Toggle("Show", isOn: enabled)
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 11))
    }

    private var visibilitySelection: Binding<EntityVisibilityChoice> {
        Binding {
            EntityVisibilityChoice(visibility: row.override.visibility)
        } set: { choice in
            viewModel.setEntityVisibility(row.id, choice.visibility)
        }
    }

    private var pinned: Binding<Bool> {
        Binding {
            row.override.pinned ?? false
        } set: { isPinned in
            viewModel.setEntityPinned(row.id, isPinned ? true : nil)
        }
    }

    private var enabled: Binding<Bool> {
        Binding {
            row.override.enabled ?? true
        } set: { isEnabled in
            viewModel.setEntityEnabled(row.id, isEnabled ? nil : false)
        }
    }
}

private enum EntityVisibilityChoice: Hashable, CaseIterable, Identifiable {
    case defaultValue
    case always
    case auto
    case never

    var id: Self { self }

    init(visibility: GlanceVisibility?) {
        switch visibility {
        case .always: self = .always
        case .auto: self = .auto
        case .never: self = .never
        case nil: self = .defaultValue
        }
    }

    var visibility: GlanceVisibility? {
        switch self {
        case .defaultValue: return nil
        case .always: return .always
        case .auto: return .auto
        case .never: return .never
        }
    }

    func title(defaultVisibility: GlanceVisibility) -> String {
        switch self {
        case .defaultValue: return "Default (\(defaultVisibility.rawValue.capitalized))"
        case .always: return "Always"
        case .auto: return "Auto"
        case .never: return "Never"
        }
    }
}

private struct SlotsSettingsDetail: View {
    let slots: [Slot]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Slots").font(.system(size: 22, weight: .bold))
                    Text("Menu bar surfaces configured for this engine.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if slots.isEmpty {
                    Text("No slots configured.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(slots) { slot in
                            SlotSettingsRow(slot: slot)
                            if slot.id != slots.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

private struct SlotSettingsRow: View {
    let slot: Slot

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.title ?? slot.id.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                Text(slot.id.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(readoutLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(selectionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var readoutLabel: String {
        switch slot.barReadout {
        case .dynamic: return "Dynamic"
        case .fixed(let id): return "Fixed: \(id.rawValue)"
        }
    }

    private var selectionLabel: String {
        switch slot.selection {
        case .integration(let id): return "Integration: \(id.rawValue)"
        case .integrations(let ids): return "Integrations: \(ids.count)"
        case .integrationType(let id): return "Type: \(id.rawValue)"
        case .capability(let capability): return "Capability: \(capability.rawValue)"
        case .entities(let ids): return "Entities: \(ids.count)"
        }
    }
}

private struct EmptySettingsDetail: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(message).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
