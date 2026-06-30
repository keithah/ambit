import AmbitCore
import AmbitUI
import AppKit
import SwiftUI

private enum SettingsSelection: Hashable {
    case integration(IntegrationInstanceID)
    case app
    case slots
    case history
    case diagnostics
    case notifications
    case automations
    case contexts
}

private func statusColor(_ status: IntegrationInstanceStatus, palette: StatusStylePalette = StatusStylePalette()) -> Color {
    switch status.severity {
    case .down, .alerting:
        return DisplayTone.bad.color(using: palette)
    case .degraded:
        return DisplayTone.warn.color(using: palette)
    case .elevated:
        return DisplayTone.warn.color(using: palette)
    case .normal:
        return (status.availability == .online ? DisplayTone.good : DisplayTone.neutral).color(using: palette)
    case nil:
        return (status.availability == .online ? DisplayTone.good : DisplayTone.neutral).color(using: palette)
    }
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
                    sidebarIntegrationButton(group)
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
                sidebarButton(
                    title: "Notifications",
                    subtitle: "\(viewModel.userRules(for: .notifications).count) custom rules",
                    systemImage: "bell",
                    selection: .notifications
                )
                sidebarButton(
                    title: "Automations",
                    subtitle: "\(viewModel.userRules(for: .automations).count) active rules",
                    systemImage: "wand.and.stars",
                    selection: .automations
                )
                sidebarButton(
                    title: "Contexts",
                    subtitle: "\(viewModel.activeContexts.count) active",
                    systemImage: "rectangle.3.group",
                    selection: .contexts
                )
                sidebarButton(
                    title: "Diagnostics",
                    subtitle: "State and logs",
                    systemImage: "stethoscope",
                    selection: .diagnostics
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

    private func sidebarIntegrationButton(_ group: IntegrationSettingsGroup) -> some View {
        Button {
            selection = .integration(group.id)
            didChooseInitialSelection = true
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(group.status, palette: viewModel.statusStylePalette))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(group.status.text)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.displayName).lineLimit(1)
                        if group.isPrimary {
                            Text("PRIMARY")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(selection == .integration(group.id) ? 0.35 : 0.16), in: Capsule())
                        }
                    }
                    Text("\(group.integrationID.rawValue) · \(group.status.text)")
                        .font(.system(size: 11))
                        .foregroundStyle(selection == .integration(group.id) ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selection == .integration(group.id) ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(selection == .integration(group.id) ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.displayName)
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
        case .diagnostics:
            DiagnosticsSettingsDetail()
        case .notifications:
            RuleSettingsDetail(pane: .notifications)
        case .automations:
            RuleSettingsDetail(pane: .automations)
        case .contexts:
            ContextSettingsDetail()
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

private struct ContextSettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var draftName = "New context"
    @State private var selectedSignalID: EntityID?
    @State private var comparison: AlertComparison = .equal
    @State private var valueText = "true"
    @State private var temporal: TemporalSelection = .held60
    @State private var overlayEntityID: EntityID?
    @State private var overlayVisibility: GlanceVisibility = .always
    @State private var overlayAlertKindID: AlertKindID?
    @State private var overlayAlertEnabled = false
    @State private var saveError: String?

    private var descriptors: [EntityDescriptor] { viewModel.userRuleSignalDescriptors }
    private var pickerItems: [SignalPickerItem] { SignalPickerModel.items(from: descriptors) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Contexts").font(.system(size: 22, weight: .bold))
                    Text("Detected situations that stack presentation and alert overlays.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                activeChips
                contextList
                contextBuilder
                traceInspector
            }
            .padding(22)
        }
    }

    private var activeChips: some View {
        HStack(spacing: 8) {
            Text("Active")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if viewModel.activeContexts.isEmpty {
                Text("Base")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            } else {
                ForEach(viewModel.activeContexts) { context in
                    Text(context.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                }
            }
        }
    }

    private var contextList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ranked contexts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if viewModel.contextDiagnostics.isEmpty == false {
                ForEach(viewModel.contextDiagnostics, id: \.message) { diagnostic in
                    Text(diagnostic.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            if viewModel.contexts.isEmpty {
                Text("No contexts yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.contexts.sorted { $0.priority < $1.priority }) { context in
                    ContextRow(context: context)
                    Divider()
                }
            }
        }
    }

    private var contextBuilder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New context")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Context name", text: $draftName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text("When").font(.system(size: 12, weight: .medium))
                Picker("Signal", selection: signalBinding) {
                    Text("Choose a signal").tag(Optional<EntityID>.none)
                    ForEach(pickerItems) { item in
                        Text("\(item.title) · \(item.subtitle)").tag(Optional(item.id))
                    }
                }
                .frame(width: 230)
                Picker("Comparison", selection: $comparison) {
                    ForEach(Self.comparisons, id: \.self) { comparison in
                        Text(Self.label(for: comparison)).tag(comparison)
                    }
                }
                .frame(width: 90)
                TextField("Value", text: $valueText).frame(width: 90)
            }
            HStack(spacing: 8) {
                Text("Dwell").font(.system(size: 12, weight: .medium))
                Picker("Dwell", selection: $temporal) {
                    Text("Immediate").tag(TemporalSelection.none)
                    Text("Held 60s").tag(TemporalSelection.held60)
                    Text("2 samples").tag(TemporalSelection.twoSamples)
                }
                .frame(width: 150)
            }
            Text(expressionPreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 8) {
                Text("While active")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    Picker("Entity", selection: overlayEntityBinding) {
                        Text("No entity visibility").tag(Optional<EntityID>.none)
                        ForEach(pickerItems) { item in
                            Text(item.title).tag(Optional(item.id))
                        }
                    }
                    .frame(width: 220)
                    Picker("Visibility", selection: $overlayVisibility) {
                        ForEach([GlanceVisibility.always, .auto, .never], id: \.self) { visibility in
                            Text(visibility.rawValue.capitalized).tag(visibility)
                        }
                    }
                    .frame(width: 120)
                }
                HStack(spacing: 8) {
                    Picker("Alert kind", selection: alertKindBinding) {
                        Text("No alert toggle").tag(Optional<AlertKindID>.none)
                        ForEach(viewModel.alertKindSettingsRows()) { row in
                            Text("\(row.integrationName) · \(row.title)").tag(Optional(row.kindID))
                        }
                    }
                    .frame(width: 260)
                    Toggle("Enabled while active", isOn: $overlayAlertEnabled)
                        .toggleStyle(.checkbox)
                }
            }

            if let saveError {
                Text(saveError).font(.system(size: 11)).foregroundStyle(.red)
            }
            Button("Add context") { save() }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var traceInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if viewModel.contextResolutionTraces.isEmpty {
                Text("Base configuration is active. No context overlay has changed a value.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.contextResolutionTraces.keys.sorted(by: traceAddressSort), id: \.self) { address in
                    if let trace = viewModel.contextResolutionTraces[address] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(label(for: address)).font(.system(size: 12, weight: .medium))
                            Text(trace.layers.map(label(for:)).joined(separator: " -> "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var signalBinding: Binding<EntityID?> {
        Binding { selectedSignalID } set: { selectedSignalID = $0 }
    }

    private var overlayEntityBinding: Binding<EntityID?> {
        Binding { overlayEntityID } set: { overlayEntityID = $0 }
    }

    private var alertKindBinding: Binding<AlertKindID?> {
        Binding { overlayAlertKindID } set: { overlayAlertKindID = $0 }
    }

    private var parsedValue: ConditionValue {
        if valueText == "true" { return .bool(true) }
        if valueText == "false" { return .bool(false) }
        if let number = Double(valueText) { return .number(number) }
        return .string(valueText)
    }

    private var condition: Condition? {
        guard let selectedSignalID else { return nil }
        let comparisonCondition = Condition.comparison(Comparison(lhs: .address(selectedSignalID), comparison: comparison, rhs: .literal(parsedValue)))
        switch temporal {
        case .none:
            return comparisonCondition
        case .held60:
            return .temporal(Temporal(condition: comparisonCondition, op: .heldFor(60), edge: .level))
        case .twoSamples:
            return .temporal(Temporal(condition: comparisonCondition, op: .consecutiveSamples(2), edge: .level))
        }
    }

    private var expressionPreview: String {
        guard let condition else { return "Choose a signal to preview the activation condition." }
        return UserRuleExpressionFormatter.string(for: condition, descriptors: descriptors)
    }

    private func save() {
        guard let condition else {
            saveError = "Choose a signal."
            return
        }
        var overlay = ContextOverlay()
        if let overlayEntityID {
            overlay.entityOverrides[overlayEntityID] = EntityPresentationOverride(visibility: overlayVisibility)
        }
        if let overlayAlertKindID {
            overlay.alertKindOverrides[overlayAlertKindID] = AlertKindOverride(enabled: overlayAlertEnabled)
        }
        let nextPriority = (viewModel.contexts.map(\.priority).max() ?? -1) + 1
        let context = ContextDeclaration(
            id: ContextID(rawValue: "context.\(UUID().uuidString)"),
            displayName: draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New context" : draftName,
            condition: condition,
            priority: nextPriority,
            overlay: overlay
        )
        viewModel.createContext(context)
        draftName = "New context"
        saveError = nil
    }

    private func traceAddressSort(_ lhs: ContextTraceAddress, _ rhs: ContextTraceAddress) -> Bool {
        label(for: lhs) < label(for: rhs)
    }

    private func label(for address: ContextTraceAddress) -> String {
        switch address {
        case .entity(let id): return "Entity \(id.rawValue)"
        case .integration(let id): return "Integration \(id.rawValue)"
        case .slot(let id): return "Slot \(id.rawValue)"
        case .alertKind(let id): return "Alert \(id.rawValue)"
        case .entityAlertKind(let entityID, let kindID): return "Alert \(kindID.rawValue) on \(entityID.rawValue)"
        }
    }

    private func label(for layer: ContextTraceLayer) -> String {
        switch layer.source {
        case .base:
            return "Base"
        case .context(let id):
            return layer.contextName ?? id.rawValue
        }
    }

    private static let comparisons: [AlertComparison] = [.greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .equal, .notEqual]

    private static func label(for comparison: AlertComparison) -> String {
        switch comparison {
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .equal: return "=="
        case .notEqual: return "!="
        }
    }

    private enum TemporalSelection: Hashable {
        case none
        case held60
        case twoSamples
    }
}

private struct ContextRow: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let context: ContextDeclaration

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(context.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    if viewModel.activeContexts.contains(where: { $0.id == context.id }) {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    }
                }
                Text(UserRuleExpressionFormatter.string(for: context.condition, descriptors: viewModel.userRuleSignalDescriptors))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Picker("Mode", selection: manualOverrideBinding) {
                Text("Auto").tag(ContextManualOverride.auto)
                Text("Pinned active").tag(ContextManualOverride.pinnedActive)
                Text("Pinned inactive").tag(ContextManualOverride.pinnedInactive)
            }
            .labelsHidden()
            .frame(width: 135)
            Button("Up") { move(-1) }.disabled(context.priority == viewModel.contexts.map(\.priority).min())
            Button("Down") { move(1) }.disabled(context.priority == viewModel.contexts.map(\.priority).max())
            Button("Delete", role: .destructive) { viewModel.deleteContext(id: context.id) }
        }
        .padding(.vertical, 8)
    }

    private var manualOverrideBinding: Binding<ContextManualOverride> {
        Binding {
            context.manualOverride
        } set: { value in
            var copy = context
            copy.manualOverride = value
            viewModel.updateContext(copy)
        }
    }

    private func move(_ delta: Int) {
        let ordered = viewModel.contexts.sorted { $0.priority < $1.priority }
        guard let index = ordered.firstIndex(where: { $0.id == context.id }) else { return }
        let newIndex = min(max(0, index + delta), ordered.count - 1)
        guard newIndex != index else { return }
        var ids = ordered.map(\.id)
        let id = ids.remove(at: index)
        ids.insert(id, at: newIndex)
        viewModel.reorderContexts(ids: ids)
    }
}

private struct RuleSettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let pane: UserRuleSettingsPane

    private var rules: [UserRule] {
        viewModel.userRules(for: pane)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved rules")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if rules.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(rules) { rule in
                            UserRuleRow(rule: rule, descriptors: viewModel.userRuleSignalDescriptors)
                            Divider()
                        }
                    }
                }

                UserRuleBuilderView(pane: pane)
            }
            .padding(22)
        }
    }

    private var title: String {
        switch pane {
        case .notifications: return "Notifications"
        case .automations: return "Automations"
        }
    }

    private var subtitle: String {
        switch pane {
        case .notifications:
            return "Built-in alerts and custom notify rules share one rule engine."
        case .automations:
            return "Rules with surface changes or commands also appear here."
        }
    }

    private var emptyMessage: String {
        switch pane {
        case .notifications: return "No custom notification rules yet."
        case .automations: return "No automation reactions yet."
        }
    }
}

private struct UserRuleRow: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let rule: UserRule
    let descriptors: [EntityDescriptor]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(rule.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Text(UserRuleExpressionFormatter.string(for: rule.condition, descriptors: descriptors))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    ForEach(reactionLabels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }
            }
            Spacer()
            Button("Delete", role: .destructive) {
                viewModel.deleteUserRule(id: rule.id)
            }
        }
        .padding(.vertical, 8)
    }

    private var reactionLabels: [String] {
        rule.reactions.map { reaction in
            switch reaction {
            case .notify: return "Notify"
            case .mutateSurface: return "Change surface"
            case .runCommand: return "Run command"
            case .applyContext: return "Apply context"
            }
        }
    }
}

private struct UserRuleBuilderView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let pane: UserRuleSettingsPane
    @State private var draft = UserRuleBuilderDraft(
        displayName: "New rule",
        reactions: [.notify(NotifySpec(titleTemplate: "Rule matched", level: .active, lifecycle: .oneShot))]
    )
    @State private var valueText = "90"
    @State private var saveError: String?

    private var descriptors: [EntityDescriptor] { viewModel.userRuleSignalDescriptors }
    private var pickerItems: [SignalPickerItem] { SignalPickerModel.items(from: descriptors) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New rule")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Rule name", text: $draft.displayName)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Text("When")
                        .font(.system(size: 12, weight: .medium))
                    Picker("Signal", selection: selectedSignalBinding) {
                        Text("Choose a signal").tag(Optional<EntityID>.none)
                        ForEach(pickerItems) { item in
                            Text("\(item.title) · \(item.subtitle)").tag(Optional(item.id))
                        }
                    }
                    .frame(width: 230)

                    Picker("Comparison", selection: $draft.comparison) {
                        ForEach(Self.comparisons, id: \.self) { comparison in
                            Text(Self.label(for: comparison)).tag(comparison)
                        }
                    }
                    .frame(width: 90)

                    TextField("Value", text: $valueText)
                        .frame(width: 80)
                }

                HStack(spacing: 8) {
                    Text("Temporal")
                        .font(.system(size: 12, weight: .medium))
                    Picker("Temporal", selection: temporalSelection) {
                        Text("Immediate").tag(TemporalSelection.none)
                        Text("Held 60s").tag(TemporalSelection.held60)
                        Text("2 samples").tag(TemporalSelection.twoSamples)
                    }
                    .frame(width: 140)
                }

                Text(expressionPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Then")
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 8) {
                        Toggle("Notify", isOn: notifyBinding)
                            .toggleStyle(.checkbox)
                        Button("Change surface") { addSurfaceMutation() }
                        Button("Run command") { addFirstCommandIfAvailable() }
                        Button("Apply context") {}
                            .disabled(true)
                            .help("Contexts arrive in B4.")
                        Button("Run Shortcut") {}
                            .disabled(true)
                            .help("Shortcuts arrive in B6.")
                    }
                    .buttonStyle(.bordered)
                }

                if let saveError {
                    Text(saveError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                Button("Add rule") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var selectedSignalBinding: Binding<EntityID?> {
        Binding {
            draft.selectedSignalID
        } set: { value in
            draft.selectedSignalID = value
        }
    }

    private var notifyBinding: Binding<Bool> {
        Binding {
            draft.reactions.contains {
                if case .notify = $0 { return true }
                return false
            }
        } set: { enabled in
            draft.reactions.removeAll {
                if case .notify = $0 { return true }
                return false
            }
            if enabled {
                draft.reactions.insert(
                    .notify(NotifySpec(titleTemplate: draft.displayName.isEmpty ? "Rule matched" : draft.displayName, level: .active, lifecycle: .oneShot)),
                    at: 0
                )
            }
        }
    }

    private var temporalSelection: Binding<TemporalSelection> {
        Binding {
            switch draft.temporal {
            case .heldFor(60): return .held60
            case .consecutiveSamples(2): return .twoSamples
            default: return .none
            }
        } set: { value in
            switch value {
            case .none: draft.temporal = nil
            case .held60: draft.temporal = .heldFor(60)
            case .twoSamples: draft.temporal = .consecutiveSamples(2)
            }
        }
    }

    private var expressionPreview: String {
        var copy = draft
        copy.comparisonValue = parsedValue
        guard let rule = try? copy.buildRule(id: "preview", descriptors: descriptors) else {
            return "Choose a signal and reaction to preview the condition."
        }
        return UserRuleExpressionFormatter.string(for: rule.condition, descriptors: descriptors)
    }

    private var parsedValue: ConditionValue {
        if let number = Double(valueText) {
            return .number(number)
        }
        return .string(valueText)
    }

    private func save() {
        var copy = draft
        copy.comparisonValue = parsedValue
        if copy.reactions.isEmpty {
            saveError = "Choose at least one reaction."
            return
        }
        do {
            let rule = try copy.buildRule(id: UserRuleID(rawValue: "user.\(UUID().uuidString)"), descriptors: descriptors)
            viewModel.createUserRule(rule)
            draft = UserRuleBuilderDraft(
                displayName: "New rule",
                selectedSignalID: draft.selectedSignalID,
                reactions: [.notify(NotifySpec(titleTemplate: "Rule matched", level: .active, lifecycle: .oneShot))]
            )
            valueText = "90"
            saveError = nil
        } catch {
            saveError = String(describing: error)
        }
    }

    private func addSurfaceMutation() {
        guard !draft.reactions.contains(where: { if case .mutateSurface = $0 { return true }; return false }) else { return }
        draft.reactions.append(.mutateSurface(SurfaceMutation(
            target: SurfacePropertyAddress(surfaceID: "menubar", itemID: "rule", property: .badge),
            set: .string("!")
        )))
    }

    private func addFirstCommandIfAvailable() {
        guard !draft.reactions.contains(where: { if case .runCommand = $0 { return true }; return false }) else { return }
        guard let command = viewModel.presentationSettings.integrations.flatMap(\.commands).first else {
            saveError = "No command is available for the current integrations."
            return
        }
        draft.reactions.append(.runCommand(CommandInvocation(
            providerID: command.providerID,
            commandID: command.command.id,
            requiresConfirmation: command.command.requiresConfirmation
        )))
    }

    private static let comparisons: [AlertComparison] = [
        .greaterThan,
        .greaterThanOrEqual,
        .lessThan,
        .lessThanOrEqual,
        .equal,
        .notEqual
    ]

    private static func label(for comparison: AlertComparison) -> String {
        switch comparison {
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .equal: return "=="
        case .notEqual: return "!="
        }
    }

    private enum TemporalSelection: Hashable {
        case none
        case held60
        case twoSamples
    }
}

private struct IntegrationSettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let group: IntegrationSettingsGroup
    @State private var actionError: String?

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
                Circle()
                    .fill(statusColor(group.status, palette: viewModel.statusStylePalette))
                    .frame(width: 9, height: 9)
                Text(group.displayName).font(.system(size: 22, weight: .bold))
                if group.isPrimary {
                    Text("PRIMARY")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                }
                Spacer()
                Toggle("Enabled", isOn: enabledBinding)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 12) {
                Text("\(group.integrationID.rawValue) · \(group.status.text)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(group.isPrimary ? "Primary" : "Set as Primary") {
                    do {
                        try viewModel.setPrimaryIntegrationInstance(group.id)
                        actionError = nil
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .disabled(group.isPrimary)
                if let test = group.commands.first(where: { $0.role == .testConnection }) {
                    Button("Test") {
                        Task { await viewModel.executeInstanceCommand(test) }
                    }
                    .accessibilityLabel("Test connection")
                }
            }
            if let actionError {
                Text(actionError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            group.enabled
        } set: { enabled in
            do {
                try viewModel.setIntegrationInstanceEnabled(group.id, enabled)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
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

            if group.presets.isEmpty == false {
                HStack(spacing: 8) {
                    ForEach(group.presets) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            if let systemImage = preset.systemImage {
                                Label(preset.title, systemImage: systemImage)
                            } else {
                                Text(preset.title)
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

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

    private func apply(_ preset: IntegrationPreset) {
        for (key, value) in preset.values {
            model.values[key] = value
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: IntegrationConfigField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
            if let description = selectedOptionDescription(field) {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 162)
            }
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

    private func selectedOptionDescription(_ field: IntegrationConfigField) -> String? {
        guard field.kind == .select else { return nil }
        let selected = model.values[field.id]?.stringValue ?? field.defaultValue?.stringValue ?? field.options?.first?.value
        return field.options?.first { $0.value == selected }?.description
    }

    private static func initialValues(group: IntegrationSettingsGroup, schema: IntegrationConfigSchema) -> [String: JSONValue] {
        var values = group.configValues
        if values["name"] == nil {
            values["name"] = .string(group.displayName)
        }
        if values["monitoringRole"] == nil {
            values["monitoringRole"] = values["tier"] ?? .string("auto")
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
                    Picker("Range", selection: graphRange) {
                        Text("Default").tag(GraphRange?.none)
                        ForEach(GraphRange.allCases, id: \.self) { range in
                            Text(range.label).tag(Optional(range))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
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

    private var graphRange: Binding<GraphRange?> {
        Binding {
            viewModel.slotGraphRange(slot.id)
        } set: { range in
            viewModel.setSlotGraphRange(slot.id, range)
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
