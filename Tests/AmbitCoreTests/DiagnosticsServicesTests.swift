import XCTest
@testable import AmbitMenuBar

final class DiagnosticsServicesTests: XCTestCase {
    func testDebugLogActionsCallInjectedService() throws {
        let service = RecordingDiagnosticsLogService()

        XCTAssertEqual(service.logURL.path, "/tmp/ambit-test.log")
        try service.reveal()
        try service.copyPath()
        try service.clear()

        XCTAssertEqual(service.actions, ["reveal", "copyPath", "clear"])
    }
}

private final class RecordingDiagnosticsLogService: DiagnosticsLogService {
    let logURL = URL(fileURLWithPath: "/tmp/ambit-test.log")
    var actions: [String] = []

    func reveal() throws { actions.append("reveal") }
    func copyPath() throws { actions.append("copyPath") }
    func clear() throws { actions.append("clear") }
}
