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
                if let schema = group.configSchema {
                    IntegrationConfigForm(group: group, schema: schema)
                }
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

struct IntegrationConfigValidationError: Equatable, Sendable {
    var fieldID: String
    var message: String
}

struct IntegrationConfigFormModel: Equatable, Sendable {
    var schema: IntegrationConfigSchema
    var values: [String: JSONValue]

    init(schema: IntegrationConfigSchema, values: [String: JSONValue]) {
        self.schema = schema
        self.values = values
    }

    var validationErrors: [IntegrationConfigValidationError] {
        schema.fields.compactMap(validate)
    }

    func draft(integrationID: IntegrationID, replacing id: IntegrationInstanceID) -> IntegrationInstanceDraft {
        IntegrationInstanceDraft(integrationID: integrationID, replacing: id, values: values)
    }

    private func validate(_ field: IntegrationConfigField) -> IntegrationConfigValidationError? {
        let value = values[field.id] ?? field.defaultValue
        if field.required, isMissing(value, kind: field.kind) {
            return IntegrationConfigValidationError(fieldID: field.id, message: "\(field.title) is required.")
        }
        guard let value, value != .null else { return nil }

        switch field.kind {
        case .text:
            guard value.stringValue != nil else {
                return IntegrationConfigValidationError(fieldID: field.id, message: "\(field.title) must be text.")
            }
        case .number:
            guard let number = value.numberValue else {
                return IntegrationConfigValidationError(fieldID: field.id, message: "\(field.title) must be a number.")
            }
            if let range = field.range, number < range.min || number > range.max {
                return IntegrationConfigValidationError(fieldID: field.id, message: "\(field.title) must be between \(range.min) and \(range.max).")
            }
        case .toggle:
            guard value.boolValue != nil else {
                return IntegrationConfigValidationError(fieldID: field.id, message: "\(field.title) must be on or off.")
            }
        case .select:
            guard let selected = value.stringValue,
                  field.options?.contains(where: { $0.value == selected }) ?? false else {
                return IntegrationConfigValidationError(fieldID: field.id, message: "\(field.title) must be one of the listed options.")
            }
        }
        return nil
    }

    private func isMissing(_ value: JSONValue?, kind: ConfigFieldKind) -> Bool {
        guard let value, value != .null else { return true }
        if kind == .text {
            return value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        return false
    }
}

private struct IntegrationConfigForm: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let group: IntegrationSettingsGroup
    let schema: IntegrationConfigSchema
    @State private var model: IntegrationConfigFormModel
    @State private var saveError: String?

    init(group: IntegrationSettingsGroup, schema: IntegrationConfigSchema) {
        self.group = group
        self.schema = schema
        _model = State(initialValue: IntegrationConfigFormModel(schema: schema, values: Self.initialValues(group: group, schema: schema)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configuration")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(schema.fields) { field in
                    fieldRow(field)
                }
            }

            if !model.validationErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.validationErrors, id: \.fieldID) { error in
                        Text(error.message)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.red)
            }

            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Button("Save") {
                do {
                    try viewModel.saveIntegrationInstanceDraft(model.draft(integrationID: group.integrationID, replacing: group.id))
                    saveError = nil
                } catch {
                    saveError = error.localizedDescription
                }
            }
            .disabled(!model.validationErrors.isEmpty)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: IntegrationConfigField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(field.title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 150, alignment: .leading)
            switch field.kind {
            case .text:
                TextField(field.title, text: textBinding(field))
            case .number:
                TextField(field.title, text: numberBinding(field))
                    .frame(width: 120)
            case .toggle:
                Toggle("", isOn: toggleBinding(field))
                    .labelsHidden()
            case .select:
                Picker(field.title, selection: selectBinding(field)) {
                    ForEach(field.options ?? [], id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            Spacer(minLength: 0)
        }
    }

    private func textBinding(_ field: IntegrationConfigField) -> Binding<String> {
        Binding {
            model.values[field.id]?.stringValue ?? field.defaultValue?.stringValue ?? ""
        } set: { value in
            model.values[field.id] = .string(value)
        }
    }

    private func numberBinding(_ field: IntegrationConfigField) -> Binding<String> {
        Binding {
            if let number = model.values[field.id]?.numberValue ?? field.defaultValue?.numberValue {
                return number.formatted()
            }
            return model.values[field.id]?.stringValue ?? ""
        } set: { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.values[field.id] = nil
            } else if let number = Double(value) {
                model.values[field.id] = .number(number)
            } else {
                model.values[field.id] = .string(value)
            }
        }
    }

    private func toggleBinding(_ field: IntegrationConfigField) -> Binding<Bool> {
        Binding {
            model.values[field.id]?.boolValue ?? field.defaultValue?.boolValue ?? false
        } set: { value in
            model.values[field.id] = .bool(value)
        }
    }

    private func selectBinding(_ field: IntegrationConfigField) -> Binding<String> {
        Binding {
            model.values[field.id]?.stringValue ?? field.defaultValue?.stringValue ?? field.options?.first?.value ?? ""
        } set: { value in
            model.values[field.id] = .string(value)
        }
    }

    private static func initialValues(group: IntegrationSettingsGroup, schema: IntegrationConfigSchema) -> [String: JSONValue] {
        var values = group.configValues
        if values["name"] == nil {
            values["name"] = .string(group.displayName)
        }
        for field in schema.fields where values[field.id] == nil {
            values[field.id] = field.defaultValue
        }
        return values
    }
}

private struct EntitySettingsRowView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var advancedExpanded = false
    let row: EntitySettingsRow

    private var readout: EntityReadout {
        EntityReadout.make(descriptor: row.descriptor, state: row.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if hasAdvancedControls {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    advancedControls
                        .padding(.top, 6)
                }
                .font(.system(size: 11))
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

    private var hasAdvancedControls: Bool {
        supportsThreshold || supportsGraphStyle || supportsGraphRange || supportsAlertPolicy
    }

    private var supportsThreshold: Bool {
        row.descriptor.kind == .sensor || row.descriptor.kind == .number
    }

    private var supportsGraphStyle: Bool {
        row.descriptor.kind == .sensor || row.descriptor.kind == .number
    }

    private var supportsGraphRange: Bool {
        supportsGraphStyle && graphRanges(for: effectiveGraphStyle).isEmpty == false
    }

    private var supportsAlertPolicy: Bool {
        row.descriptor.kind == .sensor || row.descriptor.kind == .binarySensor || row.descriptor.kind == .number
    }

    private var effectiveGraphStyle: GraphStyle? {
        row.override.graphStyle ?? row.descriptor.graphStyle
    }

    private var effectiveThreshold: DisplayThreshold {
        row.override.displayThreshold ?? row.descriptor.displayThreshold ?? DisplayThreshold(comparison: .greaterThan, value: 0, consecutive: 1)
    }

    private var effectiveAlertPolicy: AlertPolicy {
        row.override.alertPolicy ?? .preset(.balanced)
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if supportsThreshold {
                thresholdControls
            }
            if supportsGraphStyle {
                graphControls
            }
            if supportsAlertPolicy {
                alertPolicyControls
            }
        }
    }

    private var thresholdControls: some View {
        HStack(spacing: 8) {
            Text("Threshold")
                .frame(width: 90, alignment: .leading)
            Picker("Comparison", selection: thresholdComparison) {
                ForEach(AlertComparisonChoice.allCases) { choice in
                    Text(choice.label).tag(choice.comparison)
                }
            }
            .labelsHidden()
            .frame(width: 76)
            TextField("Value", text: thresholdValue)
                .frame(width: 86)
            Stepper("Sustained \(effectiveThreshold.consecutive)", value: thresholdConsecutive, in: 1...100)
                .frame(width: 150)
            Button("Reset") {
                viewModel.setEntityDisplayThreshold(row.id, nil)
            }
        }
    }

    private var graphControls: some View {
        HStack(spacing: 8) {
            Text("Graph")
                .frame(width: 90, alignment: .leading)
            Picker("Style", selection: graphStyleSelection) {
                Text("Default").tag(GraphStyle?.none)
                ForEach(GraphStyleChoice.allCases) { choice in
                    Text(choice.label).tag(Optional(choice.style))
                }
            }
            .labelsHidden()
            .frame(width: 130)

            if supportsGraphRange {
                Picker("Range", selection: graphRangeSelection) {
                    Text("Default").tag(GraphRange?.none)
                    ForEach(graphRanges(for: effectiveGraphStyle), id: \.self) { range in
                        Text(range.label).tag(Optional(range))
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }
        }
    }

    private var alertPolicyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Alerts")
                    .frame(width: 90, alignment: .leading)
                Toggle("Enabled", isOn: alertPolicyEnabled)
                    .toggleStyle(.checkbox)
                Picker("Preset", selection: alertPolicyPreset) {
                    ForEach(AlertPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                Button("Reset") {
                    viewModel.setEntityAlertPolicy(row.id, nil)
                }
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 90)
                TextField("Cooldown", text: alertPolicyCooldown)
                    .frame(width: 86)
                Toggle("Notify on recovery", isOn: alertPolicyNotifyOnRecovery)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var thresholdComparison: Binding<AlertComparison> {
        Binding {
            effectiveThreshold.comparison
        } set: { comparison in
            var threshold = effectiveThreshold
            threshold.comparison = comparison
            viewModel.setEntityDisplayThreshold(row.id, threshold)
        }
    }

    private var thresholdValue: Binding<String> {
        Binding {
            effectiveThreshold.value.formatted()
        } set: { value in
            guard let number = Double(value) else { return }
            var threshold = effectiveThreshold
            threshold.value = number
            viewModel.setEntityDisplayThreshold(row.id, threshold)
        }
    }

    private var thresholdConsecutive: Binding<Int> {
        Binding {
            effectiveThreshold.consecutive
        } set: { consecutive in
            var threshold = effectiveThreshold
            threshold.consecutive = consecutive
            viewModel.setEntityDisplayThreshold(row.id, threshold)
        }
    }

    private var graphStyleSelection: Binding<GraphStyle?> {
        Binding {
            row.override.graphStyle
        } set: { style in
            viewModel.setEntityGraphStyle(row.id, style)
        }
    }

    private var graphRangeSelection: Binding<GraphRange?> {
        Binding {
            row.override.graphRange
        } set: { range in
            viewModel.setEntityGraphRange(row.id, range)
        }
    }

    private var alertPolicyPreset: Binding<AlertPreset> {
        Binding {
            effectiveAlertPolicy.preset
        } set: { preset in
            viewModel.setEntityAlertPolicy(row.id, .preset(preset))
        }
    }

    private var alertPolicyEnabled: Binding<Bool> {
        Binding {
            effectiveAlertPolicy.enabled
        } set: { enabled in
            var policy = effectiveAlertPolicy
            policy.enabled = enabled
            policy.preset = .custom
            viewModel.setEntityAlertPolicy(row.id, policy)
        }
    }

    private var alertPolicyCooldown: Binding<String> {
        Binding {
            effectiveAlertPolicy.cooldown.formatted()
        } set: { value in
            guard let number = Double(value) else { return }
            var policy = effectiveAlertPolicy
            policy.cooldown = number
            policy.preset = .custom
            viewModel.setEntityAlertPolicy(row.id, policy)
        }
    }

    private var alertPolicyNotifyOnRecovery: Binding<Bool> {
        Binding {
            effectiveAlertPolicy.notifyOnRecovery
        } set: { notify in
            var policy = effectiveAlertPolicy
            policy.notifyOnRecovery = notify
            policy.preset = .custom
            viewModel.setEntityAlertPolicy(row.id, policy)
        }
    }

    private func graphRanges(for style: GraphStyle?) -> [GraphRange] {
        switch style {
        case .sparkline, nil:
            return GraphRange.allCases
        case .gauge, .progress, .some(.none):
            return []
        }
    }
}

private enum AlertComparisonChoice: CaseIterable, Identifiable {
    case greaterThan
    case lessThan
    case equal
    case notEqual

    var id: Self { self }

    var comparison: AlertComparison {
        switch self {
        case .greaterThan: return .greaterThan
        case .lessThan: return .lessThan
        case .equal: return .equal
        case .notEqual: return .notEqual
        }
    }

    var label: String {
        switch self {
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .equal: return "=="
        case .notEqual: return "!="
        }
    }
}

private enum GraphStyleChoice: CaseIterable, Identifiable {
    case sparkline
    case gauge
    case progress
    case none

    var id: Self { self }

    var style: GraphStyle {
        switch self {
        case .sparkline: return .sparkline
        case .gauge: return .gauge
        case .progress: return .progress
        case .none: return .none
        }
    }

    var label: String {
        switch self {
        case .sparkline: return "Sparkline"
        case .gauge: return "Gauge"
        case .progress: return "Progress"
        case .none: return "None"
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
