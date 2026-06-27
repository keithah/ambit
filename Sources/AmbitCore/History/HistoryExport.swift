import Foundation

public enum HistoryExportFormat: String, CaseIterable, Sendable, Codable {
    case csv
    case json
    case text
}

public struct HistoryExportRow: Equatable, Sendable, Codable {
    public var timestamp: Date
    public var name: String
    public var value: Double?
    public var ok: Bool
    public var unit: String?
    public var metadata: String?

    public init(
        timestamp: Date,
        name: String,
        value: Double?,
        ok: Bool,
        unit: String?,
        metadata: String?
    ) {
        self.timestamp = timestamp
        self.name = name
        self.value = value
        self.ok = ok
        self.unit = unit
        self.metadata = metadata
    }
}

public enum HistoryExportTarget: Hashable, Sendable, Codable {
    case entity(EntityID)
    case slot(SlotID)
}

public enum HistoryExportRange: Hashable, Sendable, Codable {
    case graph(GraphRange)
    case retention

    public var label: String {
        label(retentionInterval: HistoryService.defaultRetentionInterval)
    }

    public func label(retentionInterval: TimeInterval) -> String {
        switch self {
        case .graph(let range): return range.label
        case .retention: return Self.retentionLabel(for: retentionInterval)
        }
    }

    public func seconds(retentionInterval: TimeInterval) -> TimeInterval {
        switch self {
        case .graph(let range): return range.seconds
        case .retention: return retentionInterval
        }
    }

    public static func retentionLabel(for interval: TimeInterval) -> String {
        let days = interval / (24 * 60 * 60)
        if days >= 1, days.rounded() == days {
            let count = Int(days)
            return count == 1 ? "1 day" : "\(count) days"
        }
        let hours = interval / (60 * 60)
        if hours >= 1, hours.rounded() == hours {
            let count = Int(hours)
            return count == 1 ? "1 hour" : "\(count) hours"
        }
        let minutes = interval / 60
        if minutes >= 1, minutes.rounded() == minutes {
            let count = Int(minutes)
            return count == 1 ? "1 minute" : "\(count) minutes"
        }
        let count = Int(interval.rounded())
        return count == 1 ? "1 second" : "\(count) seconds"
    }
}

public struct HistoryExportTargetOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var target: HistoryExportTarget
    public var label: String
    public var detail: String

    public init(id: String, target: HistoryExportTarget, label: String, detail: String) {
        self.id = id
        self.target = target
        self.label = label
        self.detail = detail
    }
}

public enum HistoryExportError: Error, Equatable {
    case invalidJSON
}

public enum HistoryExport {
    public static func rows(descriptor: EntityDescriptor, samples: [Sample]) -> [HistoryExportRow] {
        samples.map { sample in
            let ok = sample.ok && sample.value != nil
            return HistoryExportRow(
                timestamp: sample.timestamp,
                name: descriptor.name,
                value: ok ? sample.value : nil,
                ok: ok,
                unit: descriptor.unit,
                metadata: sample.metadata
            )
        }
    }

    public static func rows(
        target: HistoryExportTarget,
        descriptors: [EntityDescriptor],
        slots: [Slot],
        records: [IntegrationInstanceRecord],
        samplesByEntity: [EntityID: [Sample]]
    ) -> [HistoryExportRow] {
        exportDescriptors(target: target, descriptors: descriptors, slots: slots, records: records)
            .flatMap { descriptor in
                rows(descriptor: descriptor, samples: samplesByEntity[descriptor.id] ?? [])
            }
    }

    public static func exportDescriptors(
        target: HistoryExportTarget,
        descriptors: [EntityDescriptor],
        slots: [Slot],
        records: [IntegrationInstanceRecord]
    ) -> [EntityDescriptor] {
        let resolved: [EntityDescriptor]
        switch target {
        case .entity(let id):
            resolved = descriptors.filter { $0.id == id }
        case .slot(let id):
            guard let slot = slots.first(where: { $0.id == id }) else { return [] }
            resolved = SlotResolver.resolve(slot.selection, descriptors: descriptors, records: records)
        }
        return resolved
            .filter { $0.stateClass != nil }
            .sorted { lhs, rhs in lhs.id.rawValue < rhs.id.rawValue }
    }

    public static func data(rows: [HistoryExportRow], format: HistoryExportFormat) throws -> Data {
        switch format {
        case .csv:
            return Data(csv(rows).utf8)
        case .json:
            return try json(rows)
        case .text:
            return Data(text(rows).utf8)
        }
    }

    private static func csv(_ rows: [HistoryExportRow]) -> String {
        let header = "timestamp,name,value,ok,unit,metadata"
        let body = rows.map { row in
            [
                iso8601(row.timestamp),
                row.name,
                row.value.map(formatNumber) ?? "",
                row.ok ? "true" : "false",
                row.unit ?? "",
                row.metadata ?? ""
            ].map(csvField).joined(separator: ",")
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    private static func json(_ rows: [HistoryExportRow]) throws -> Data {
        let objects: [[String: Any]] = rows.map { row in
            [
                "metadata": row.metadata as Any? ?? NSNull(),
                "name": row.name,
                "ok": row.ok,
                "timestamp": iso8601(row.timestamp),
                "unit": row.unit as Any? ?? NSNull(),
                "value": row.value as Any? ?? NSNull()
            ]
        }
        guard JSONSerialization.isValidJSONObject(objects) else {
            throw HistoryExportError.invalidJSON
        }
        return try JSONSerialization.data(
            withJSONObject: objects,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func text(_ rows: [HistoryExportRow]) -> String {
        var lines = [
            "Ambit History Export",
            "Samples: \(rows.count)",
            ""
        ]
        lines += rows.map { row in
            let result: String
            if row.ok, let value = row.value {
                result = [formatNumber(value), row.unit].compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }.joined(separator: " ")
            } else {
                result = row.metadata?.isEmpty == false ? row.metadata! : "Failed"
            }
            return "\(iso8601(row.timestamp))\t\(row.name)\t\(result)\t\(row.ok ? "OK" : "Failed")"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
