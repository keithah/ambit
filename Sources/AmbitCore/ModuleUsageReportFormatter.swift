import Foundation

public enum ModuleUsageReportFormatter {
    public static func format(_ snapshots: [ModuleUsageSnapshot]) -> String {
        var lines = ["Module usage:"]
        for snapshot in snapshots.sorted(by: { $0.providerID < $1.providerID }) {
            lines.append("  \(snapshot.providerID): \(format(snapshot))")
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ snapshot: ModuleUsageSnapshot) -> String {
        var parts = [
            "polls \(snapshot.pollCount)",
            "commands \(snapshot.commandCount)",
            "failures \(snapshot.failureCount)",
            "total \(String(format: "%.3f", snapshot.totalDuration))s"
        ]
        if let lastOperation = snapshot.lastOperation {
            parts.append("last \(lastOperation.rawValue)")
        }
        if let lastError = snapshot.lastError {
            parts.append("last error: \(singleLine(lastError))")
        }
        return parts.joined(separator: ", ")
    }

    private static func singleLine(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
