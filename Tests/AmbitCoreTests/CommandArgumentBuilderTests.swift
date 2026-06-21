import XCTest
@testable import AmbitCore

final class CommandArgumentBuilderTests: XCTestCase {
    func testValidationReportsMissingRequiredTextParameter() {
        let parameters = [
            CommandParameter(id: "host", label: "Host", kind: .text)
        ]

        let result = CommandArgumentBuilder.validate(parameters: parameters, rawValues: ["host": "  "])

        XCTAssertEqual(result, "Host is required.")
    }

    func testValidationReportsInvalidNumberParameter() {
        let parameters = [
            CommandParameter(id: "priority", label: "Priority", kind: .number)
        ]

        let result = CommandArgumentBuilder.validate(parameters: parameters, rawValues: ["priority": "fast"])

        XCTAssertEqual(result, "Priority must be a number.")
    }

    func testValidationReportsInvalidOptionParameter() {
        let parameters = [
            CommandParameter(id: "mode", label: "Mode", kind: .option(["SP", "RD", "STR"]))
        ]

        let result = CommandArgumentBuilder.validate(parameters: parameters, rawValues: ["mode": "turbo"])

        XCTAssertEqual(result, "Mode must be one of SP, RD, STR.")
    }

    func testBuildsTypedCommandArgumentsFromRawValues() {
        let parameters = [
            CommandParameter(id: "host", label: "Host", kind: .text),
            CommandParameter(id: "enabled", label: "Enabled", kind: .bool),
            CommandParameter(id: "priority", label: "Priority", kind: .number),
            CommandParameter(id: "mode", label: "Mode", kind: .option(["SP", "RD"]))
        ]

        let arguments = CommandArgumentBuilder.arguments(
            parameters: parameters,
            rawValues: [
                "host": "iperf.example",
                "enabled": "true",
                "priority": "2.5",
                "mode": "RD"
            ]
        )

        XCTAssertEqual(arguments, CommandArguments(values: [
            "host": .string("iperf.example"),
            "enabled": .bool(true),
            "priority": .number(2.5),
            "mode": .string("RD")
        ]))
    }
}
