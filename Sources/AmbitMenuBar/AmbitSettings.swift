import AmbitCore
import AmbitUI
import AppKit
import SwiftUI

private enum SettingsSelection: Hashable {
    case integration(IntegrationInstanceID)
    case app
    case slots
    case history
}

struct AmbitSettings: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var selection: SettingsSelection = .slots
    @State private var didChooseInitialSelection = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 820, height: 560)
        .onAppear { chooseInitialSelectionIfNeeded() }
        .onChange(of: viewModel.presentationSettings.integrations.map(\.id)) { _ in
            chooseInitialSelectionIfNeeded()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ambit").font(.system(size: 18, weight: .bold))
                Text("Settings").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)

            VStack(spacing: 2) {
                ForEach(sidebarGroups) { group in
                    sidebarButton(
                        title: group.displayName,
                        subtitle: group.integrationID.rawValue,
                        systemImage: "shippingbox",
                        selection: .integration(group.id)
                    )
                }
                Divider().padding(.vertical, 6)
                sidebarButton(
                    title: "App",
                    subtitle: "Launch and notifications",
                    systemImage: "app.badge",
                    selection: .app
                )
                sidebarButton(
                    title: "Slots",
                    subtitle: "\(viewModel.presentationSettings.slots.count) configured",
                    systemImage: "menubar.rectangle",
                    selection: .slots
                )
                sidebarButton(
                    title: "History",
                    subtitle: "\(viewModel.historyRetentionLabel) retained",
                    systemImage: "clock.arrow.circlepath",
                    selection: .history
                )
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sidebarGroups: [IntegrationSettingsGroup] {
        viewModel.presentationSettings.integrations.sorted { lhs, rhs in
            let lhsRank = sidebarRank(lhs)
            let rhsRank = sidebarRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sidebarRank(_ group: IntegrationSettingsGroup) -> Int {
        if group.enabled, group.configSchema != nil { return 0 }
        if group.enabled { return 1 }
        return 2
    }

    private func sidebarButton(
        title: String,
        subtitle: String,
        systemImage: String,
        selection item: SettingsSelection
    ) -> some View {
        Button {
            selection = item
            didChooseInitialSelection = true
        } label: {
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
        .accessibilityLabel(title)
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
        case .app:
            AppSettingsDetail()
        case .slots:
            SlotsSettingsDetail(slots: viewModel.presentationSettings.slots)
        case .history:
            HistorySettingsDetail()
        }
    }

    private func chooseInitialSelectionIfNeeded() {
        guard !didChooseInitialSelection,
              let first = sidebarGroups.first
        else { return }
        selection = .integration(first.id)
        didChooseInitialSelection = true
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

private struct AppSettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var notificationStatus: NotificationAuthorizationStatus = .unavailable
    @State private var notificationMessage: String?
    @State private var isRequestingNotifications = false
    @State private var isSendingTestNotification = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("App").font(.system(size: 22, weight: .bold))
                Text("Launch behavior and system integration.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Start Ambit at login", isOn: startAtLoginBinding)
                    .toggleStyle(.switch)

                if let message = viewModel.startAtLoginMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            notificationControls

            localNetworkHints

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refreshNotificationStatus() }
    }

    private var notificationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Status: \(notificationStatus.label)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Allow Notifications") { requestNotifications() }
                    .disabled(isRequestingNotifications || notificationStatus == .authorized || notificationStatus == .provisional)
                Button("Send Test") { sendTestNotification() }
                    .disabled(isSendingTestNotification)
                Button("Open Notification Settings") {
                    viewModel.openNotificationSettings()
                }
            }
            if let notificationMessage {
                Text(notificationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localNetworkHints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Network Access")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            let hints = viewModel.localNetworkPermissionHints()
            if hints.isEmpty {
                Text("No local-network targets are configured.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hints) { hint in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hint.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(hint.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func refreshNotificationStatus() {
        Task { @MainActor in
            notificationStatus = await viewModel.notificationAuthorizationStatus()
        }
    }

    private func requestNotifications() {
        isRequestingNotifications = true
        Task { @MainActor in
            notificationStatus = await viewModel.requestNotificationAuthorization()
            isRequestingNotifications = false
        }
    }

    private func sendTestNotification() {
        isSendingTestNotification = true
        notificationMessage = nil
        Task { @MainActor in
            let results = await viewModel.sendTestNotification()
            isSendingTestNotification = false
            notificationMessage = results.contains { result in
                if case .delivered = result { return true }
                return false
            } ? "Test notification sent." : "Test notification was not delivered."
            notificationStatus = await viewModel.notificationAuthorizationStatus()
        }
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding {
            viewModel.startAtLoginEnabled
        } set: { enabled in
            Task { @MainActor in
                await viewModel.setStartAtLoginEnabled(enabled)
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

    func draft(integrationID: IntegrationID, replacing id: IntegrationInstanceID?) -> IntegrationInstanceDraft {
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

            HStack(spacing: 10) {
                Button("Save") {
                    save(replacing: group.id)
                }
                .accessibilityLabel("Save configuration")
                Button("Add") {
                    save(replacing: nil)
                }
                .accessibilityLabel("Add integration instance")
                Button("Delete", role: .destructive) {
                    do {
                        try viewModel.deleteIntegrationInstance(group.id)
                        saveError = nil
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .accessibilityLabel("Delete integration instance")
            }
            .disabled(!model.validationErrors.isEmpty)
        }
    }

    private func save(replacing id: IntegrationInstanceID?) {
        do {
            try viewModel.saveIntegrationInstanceDraft(model.draft(integrationID: group.integrationID, replacing: id))
            saveError = nil
        } catch {
            saveError = error.localizedDescription
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
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        advancedExpanded.toggle()
                    } label: {
                        Label("Advanced", systemImage: advancedExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Advanced")

                    if advancedExpanded {
                        advancedControls
                            .padding(.top, 2)
                    }
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
                Picker("Comparison", selection: alertPolicyComparison) {
                    ForEach(AlertComparisonChoice.allCases) { choice in
                        Text(choice.label).tag(choice.comparison)
                    }
                }
                .labelsHidden()
                .frame(width: 76)
                TextField(alertPolicyValuePlaceholder, text: alertPolicyThresholdValue)
                    .frame(width: 86)
                Stepper("Sustained \(effectiveAlertPolicy.consecutive)", value: alertPolicyConsecutive, in: 1...100)
                    .frame(width: 150)
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

    private var alertPolicyValuePlaceholder: String {
        row.descriptor.unit.map { "Value \($0)" } ?? "Value"
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

    private var alertPolicyComparison: Binding<AlertComparison> {
        Binding {
            effectiveAlertPolicy.threshold?.comparison ?? .greaterThanOrEqual
        } set: { comparison in
            var policy = effectiveAlertPolicy
            let value = policy.threshold?.value ?? defaultAlertThresholdValue
            policy.threshold = AlertThreshold(comparison: comparison, value: value)
            policy.preset = .custom
            viewModel.setEntityAlertPolicy(row.id, policy)
        }
    }

    private var alertPolicyThresholdValue: Binding<String> {
        Binding {
            (effectiveAlertPolicy.threshold?.value ?? defaultAlertThresholdValue).formatted()
        } set: { value in
            guard let number = Double(value) else { return }
            var policy = effectiveAlertPolicy
            let comparison = policy.threshold?.comparison ?? .greaterThanOrEqual
            policy.threshold = AlertThreshold(comparison: comparison, value: number)
            policy.preset = .custom
            viewModel.setEntityAlertPolicy(row.id, policy)
        }
    }

    private var alertPolicyConsecutive: Binding<Int> {
        Binding {
            effectiveAlertPolicy.consecutive
        } set: { consecutive in
            var policy = effectiveAlertPolicy
            policy.consecutive = consecutive
            policy.preset = .custom
            viewModel.setEntityAlertPolicy(row.id, policy)
        }
    }

    private var defaultAlertThresholdValue: Double {
        row.descriptor.displayThreshold?.value ?? row.descriptor.range?.max ?? 0
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
    @EnvironmentObject private var viewModel: StatusViewModel
    let slots: [Slot]
    @State private var selectedSlotID: SlotID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(slots) { slot in
                            Button {
                                selectedSlotID = slot.id
                            } label: {
                                SlotSettingsRow(slot: slot, isSelected: selectedSlotID == slot.id)
                            }
                            .buttonStyle(.plain)
                            if slot.id != slots.last?.id { Divider() }
                        }
                    }
                    .frame(width: 220)

                    Divider()

                    if let slot = selectedSlot {
                        SlotItemsEditor(slot: slot)
                    } else {
                        Text("Select a slot.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .padding(22)
        .onAppear { selectInitialSlotIfNeeded() }
        .onChange(of: slots.map(\.id)) { _ in selectInitialSlotIfNeeded() }
    }

    private var selectedSlot: Slot? {
        guard let selectedSlotID else { return slots.first }
        return slots.first { $0.id == selectedSlotID } ?? slots.first
    }

    private func selectInitialSlotIfNeeded() {
        if selectedSlotID == nil || slots.contains(where: { $0.id == selectedSlotID }) == false {
            selectedSlotID = slots.first?.id
        }
    }
}

private struct HistorySettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var selectedTargetID: String?
    @State private var selectedRange: HistoryExportRange = .graph(.m5)
    @State private var statusMessage: String?
    @State private var isExporting = false
    @State private var isClearing = false

    private var targets: [HistoryExportTargetOption] {
        viewModel.historyExportTargetOptions()
    }

    private var selectedTarget: HistoryExportTargetOption? {
        guard let selectedTargetID else { return targets.first }
        return targets.first { $0.id == selectedTargetID } ?? targets.first
    }

    private var ranges: [HistoryExportRange] {
        GraphRange.allCases.map(HistoryExportRange.graph) + [.retention]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("History").font(.system(size: 22, weight: .bold))
                Text("Export or clear retained samples for any slot or measurement entity.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if targets.isEmpty {
                Text("No history-backed entities are available yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Target", selection: selectedTargetIDBinding) {
                        ForEach(targets) { option in
                            Text(option.label).tag(Optional(option.id))
                        }
                    }
                    .frame(width: 360)

                    Picker("Range", selection: $selectedRange) {
                        ForEach(ranges, id: \.self) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .frame(width: 180)

                    Text("Retained for \(viewModel.historyRetentionLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ForEach(HistoryExportFormat.allCases, id: \.self) { format in
                            Button(exportTitle(format)) {
                                export(format)
                            }
                        }
                        .disabled(isExporting)

                        Button("Clear", role: .destructive) {
                            clearHistory()
                        }
                        .disabled(isClearing)
                    }

                    if let selectedTarget {
                        Text(selectedTarget.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectInitialTargetIfNeeded()
        }
        .onChange(of: targets.map(\.id)) { _ in selectInitialTargetIfNeeded() }
    }

    private var selectedTargetIDBinding: Binding<String?> {
        Binding {
            selectedTarget?.id
        } set: { id in
            selectedTargetID = id
        }
    }

    private func selectInitialTargetIfNeeded() {
        if selectedTargetID == nil || targets.contains(where: { $0.id == selectedTargetID }) == false {
            selectedTargetID = targets.first?.id
        }
    }

    private func exportTitle(_ format: HistoryExportFormat) -> String {
        switch format {
        case .csv: return "Export CSV"
        case .json: return "Export JSON"
        case .text: return "Export Text"
        }
    }

    private func export(_ format: HistoryExportFormat) {
        guard let target = selectedTarget else { return }
        isExporting = true
        statusMessage = nil
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let data = try await viewModel.historyExportData(
                    target: target.target,
                    range: selectedRange,
                    format: format
                )
                try save(data: data, format: format, targetLabel: target.label)
                statusMessage = "Exported \(target.label)."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func clearHistory() {
        isClearing = true
        statusMessage = nil
        Task { @MainActor in
            await viewModel.clearHistory()
            isClearing = false
            statusMessage = "History cleared."
        }
    }

    private func save(data: Data, format: HistoryExportFormat, targetLabel: String) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(fileSafe(targetLabel))-history.\(fileExtension(format))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url)
    }

    private func fileExtension(_ format: HistoryExportFormat) -> String {
        switch format {
        case .csv: return "csv"
        case .json: return "json"
        case .text: return "txt"
        }
    }

    private func fileSafe(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        return value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension NotificationAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Provisional"
        case .unavailable: return "Unavailable"
        case .unknown(let value): return value
        }
    }
}

private struct SlotSettingsRow: View {
    let slot: Slot
    var isSelected = false

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
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
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

private struct SlotItemsEditor: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let slot: Slot

    private var items: [SurfaceComposer.SurfaceItem] {
        viewModel.surfaceItems(for: slot)
    }

    private var configuredItems: [SurfaceComposer.SurfaceItem] {
        items.filter(\.isShown)
    }

    private var availableItems: [SurfaceComposer.SurfaceItem] {
        items.filter { !$0.isShown }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(slot.title ?? slot.id.rawValue)
                        .font(.system(size: 16, weight: .semibold))
                    Text(selectionLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Stepper("Table rows \(viewModel.slotTableRowLimit(slot.id))", value: tableRowLimit, in: 1...25)
                        .font(.system(size: 11))
                    Button("Default") {
                        viewModel.setSlotTableRowLimit(slot.id, nil)
                    }
                    .font(.system(size: 11))
                }
                Button("Reset to Auto") {
                    viewModel.resetSlotSurfaceItems(slot.id)
                }
                .font(.system(size: 11))
            }

            HStack(alignment: .top, spacing: 12) {
                itemColumn(
                    title: "Configured Dashboard",
                    emptyText: "No items configured.",
                    items: configuredItems,
                    action: configuredAction
                )
                itemColumn(
                    title: "Available Items",
                    emptyText: "No available items.",
                    items: availableItems,
                    action: availableAction
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func itemColumn(
        title: String,
        emptyText: String,
        items: [SurfaceComposer.SurfaceItem],
        action: @escaping (SurfaceComposer.SurfaceItem) -> AnyView
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if items.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        ForEach(items, id: \.id) { item in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(item.section)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                action(item)
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
            .frame(minHeight: 270)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func configuredAction(_ item: SurfaceComposer.SurfaceItem) -> AnyView {
        AnyView(
            HStack(spacing: 4) {
                Button {
                    move(item.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(configuredItems.first?.id == item.id)
                .help("Move up")

                Button {
                    move(item.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(configuredItems.last?.id == item.id)
                .help("Move down")

                Button {
                    viewModel.removeSlotSurfaceItem(slot.id, item.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Remove")
            }
            .buttonStyle(.borderless)
        )
    }

    private func availableAction(_ item: SurfaceComposer.SurfaceItem) -> AnyView {
        AnyView(
            Button {
                viewModel.addSlotSurfaceItem(slot.id, item.id)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Add")
        )
    }

    private func move(_ id: SurfaceItemID, by delta: Int) {
        var ids = configuredItems.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let destination = index + delta
        guard ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        viewModel.setSlotShownItems(slot.id, ids)
    }

    private var tableRowLimit: Binding<Int> {
        Binding {
            viewModel.slotTableRowLimit(slot.id)
        } set: { limit in
            viewModel.setSlotTableRowLimit(slot.id, limit)
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
