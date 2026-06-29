import AmbitCore
import AppKit
import SwiftUI

struct DiagnosticsSettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var selectedSlotID: SlotID?
    @State private var selectedTargetID: String?
    @State private var selectedRange: HistoryExportRange = .graph(.m5)
    @State private var failures: [DiagnosticsFailureRow] = []
    @State private var message: String?

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
                Text("Diagnostics").font(.system(size: 22, weight: .bold))
                Text("Inspect current state, debug logs, and recent failed samples.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            currentStateSection
            debugLogSection
            recentFailuresSection
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectInitialValuesIfNeeded()
            reloadFailures()
        }
        .onChange(of: selectedTargetID) { _ in reloadFailures() }
        .onChange(of: selectedRange) { _ in reloadFailures() }
        .onChange(of: viewModel.presentationSettings.slots.map(\.id)) { _ in selectInitialValuesIfNeeded() }
    }

    private var currentStateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current State")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Slot", selection: selectedSlotIDBinding) {
                ForEach(viewModel.presentationSettings.slots) { slot in
                    Text(slot.title ?? slot.id.rawValue).tag(Optional(slot.id))
                }
            }
            .frame(width: 260)
            if let state = viewModel.diagnosticsCurrentState(slotID: selectedSlotID) {
                Text("\(state.slotTitle): \(state.entityName)")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(state.result) · \(state.status)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("No slot state is available yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var debugLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug Log")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(viewModel.diagnosticsLogURL.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button("Reveal") { performLogAction { try viewModel.revealDiagnosticsLog() } }
                Button("Copy Path") { performLogAction { try viewModel.copyDiagnosticsLogPath() } }
                Button("Clear", role: .destructive) { performLogAction { try viewModel.clearDiagnosticsLog() } }
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentFailuresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Failures")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if targets.isEmpty {
                Text("No history-backed targets are available yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Picker("Target", selection: selectedTargetIDBinding) {
                        ForEach(targets) { option in
                            Text(option.label).tag(Optional(option.id))
                        }
                    }
                    .frame(width: 300)

                    Picker("Range", selection: $selectedRange) {
                        ForEach(ranges, id: \.self) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .frame(width: 140)
                }

                if failures.isEmpty {
                    Text("No failed samples in this range.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(failures) { row in
                            HStack(spacing: 8) {
                                Text(row.timestamp, style: .time)
                                    .frame(width: 70, alignment: .leading)
                                Text(row.entityName)
                                    .lineLimit(1)
                                    .frame(width: 150, alignment: .leading)
                                Text(row.reason)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }

    private var selectedSlotIDBinding: Binding<SlotID?> {
        Binding {
            selectedSlotID ?? viewModel.presentationSettings.slots.first?.id
        } set: { id in
            selectedSlotID = id
        }
    }

    private var selectedTargetIDBinding: Binding<String?> {
        Binding {
            selectedTarget?.id
        } set: { id in
            selectedTargetID = id
        }
    }

    private func selectInitialValuesIfNeeded() {
        if selectedSlotID == nil || viewModel.presentationSettings.slots.contains(where: { $0.id == selectedSlotID }) == false {
            selectedSlotID = viewModel.presentationSettings.slots.first?.id
        }
        if selectedTargetID == nil || targets.contains(where: { $0.id == selectedTargetID }) == false {
            selectedTargetID = targets.first?.id
        }
    }

    private func reloadFailures() {
        guard let target = selectedTarget else {
            failures = []
            return
        }
        Task { @MainActor in
            failures = await viewModel.recentFailures(target: target.target, range: selectedRange)
        }
    }

    private func performLogAction(_ action: () throws -> Void) {
        do {
            try action()
            message = "Log action completed."
        } catch {
            message = error.localizedDescription
        }
    }
}
