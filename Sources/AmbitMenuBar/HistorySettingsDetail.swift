import AmbitCore
import AppKit
import Foundation
import SwiftUI

struct HistorySettingsDetail: View {
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
