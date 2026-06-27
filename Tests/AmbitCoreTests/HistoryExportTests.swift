import XCTest
@testable import AmbitCore

final class HistoryExportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testRowsPreserveNameUnitSuccessAndFailureMetadata() {
        let descriptor = latencyDescriptor(name: "Router, \"Office\"")
        let samples = [
            Sample(timestamp: t0, value: 12.4, ok: true, metadata: "ok note"),
            Sample(timestamp: t0.addingTimeInterval(1), value: nil, ok: false, metadata: "Timed \"out\", gateway"),
            Sample(timestamp: t0.addingTimeInterval(2), value: 99, ok: false, metadata: "Rejected")
        ]

        let rows = HistoryExport.rows(descriptor: descriptor, samples: samples)

        XCTAssertEqual(rows.map(\.timestamp), [t0, t0.addingTimeInterval(1), t0.addingTimeInterval(2)])
        XCTAssertEqual(rows.map(\.name), ["Router, \"Office\"", "Router, \"Office\"", "Router, \"Office\""])
        XCTAssertEqual(rows.map(\.value), [12.4, nil, nil])
        XCTAssertEqual(rows.map(\.ok), [true, false, false])
        XCTAssertEqual(rows.map(\.unit), ["ms", "ms", "ms"])
        XCTAssertEqual(rows.map(\.metadata), ["ok note", "Timed \"out\", gateway", "Rejected"])
    }

    func testCSVIncludesHeaderEscapesFieldsAndKeepsFailureValueEmpty() throws {
        let rows = [
            HistoryExportRow(
                timestamp: t0,
                name: "Router, \"Office\"",
                value: 12.4,
                ok: true,
                unit: "ms",
                metadata: "line one"
            ),
            HistoryExportRow(
                timestamp: t0.addingTimeInterval(1),
                name: "Router\nLab",
                value: nil,
                ok: false,
                unit: "ms",
                metadata: "Timed \"out\", gateway"
            )
        ]

        let csv = String(decoding: try HistoryExport.data(rows: rows, format: .csv), as: UTF8.self)

        let expected = [
            "timestamp,name,value,ok,unit,metadata",
            #"2023-11-14T22:13:20Z,"Router, ""Office""",12.4,true,ms,line one"#,
            "2023-11-14T22:13:21Z,\"Router\nLab\",,false,ms,\"Timed \"\"out\"\", gateway\"",
            ""
        ].joined(separator: "\n")
        XCTAssertEqual(csv, expected)
    }

    func testJSONIsDeterministicAndPreservesFailureRows() throws {
        let rows = [
            HistoryExportRow(timestamp: t0, name: "Latency", value: 6, ok: true, unit: "ms", metadata: nil),
            HistoryExportRow(timestamp: t0.addingTimeInterval(1), name: "Latency", value: nil, ok: false, unit: "ms", metadata: "Timed out")
        ]

        let first = String(decoding: try HistoryExport.data(rows: rows, format: .json), as: UTF8.self)
        let second = String(decoding: try HistoryExport.data(rows: rows, format: .json), as: UTF8.self)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, #"""
[
  {
    "metadata" : null,
    "name" : "Latency",
    "ok" : true,
    "timestamp" : "2023-11-14T22:13:20Z",
    "unit" : "ms",
    "value" : 6
  },
  {
    "metadata" : "Timed out",
    "name" : "Latency",
    "ok" : false,
    "timestamp" : "2023-11-14T22:13:21Z",
    "unit" : "ms",
    "value" : null
  }
]
"""#)
    }

    func testTextExportIsGenericAndHumanReadable() throws {
        let rows = [
            HistoryExportRow(timestamp: t0, name: "CPU", value: 35.5, ok: true, unit: "%", metadata: nil),
            HistoryExportRow(timestamp: t0.addingTimeInterval(1), name: "CPU", value: nil, ok: false, unit: "%", metadata: "No sample")
        ]

        let text = String(decoding: try HistoryExport.data(rows: rows, format: .text), as: UTF8.self)

        XCTAssertTrue(text.contains("Ambit History Export"))
        XCTAssertTrue(text.contains("Samples: 2"))
        XCTAssertTrue(text.contains("2023-11-14T22:13:20Z\tCPU\t35.5 %\tOK"))
        XCTAssertTrue(text.contains("2023-11-14T22:13:21Z\tCPU\tNo sample\tFailed"))
    }

    private func latencyDescriptor(name: String) -> EntityDescriptor {
        EntityDescriptor(
            id: "ping@office/probe.latency_ms",
            instanceID: "ping@office/probe",
            name: name,
            kind: .sensor,
            deviceClass: .latency,
            unit: "ms",
            stateClass: .measurement
        )
    }
}
