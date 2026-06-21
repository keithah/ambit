import XCTest
@testable import AmbitCore

final class CommandExecutionResultTests: XCTestCase {
    func testFormatsSuccessfulCommandMessage() {
        let result = CommandExecutionResult.success(
            providerID: "demo",
            providerName: "Demo Provider",
            commandID: "demo.restart",
            commandLabel: "Restart"
        )

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.message, "Restart sent to Demo Provider.")
        XCTAssertNil(result.errorMessage)
    }

    func testFormatsFailedCommandMessage() {
        let result = CommandExecutionResult.failure(
            providerID: "demo",
            providerName: "Demo Provider",
            commandID: "demo.restart",
            commandLabel: "Restart",
            errorMessage: "device unavailable"
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Restart failed for Demo Provider: device unavailable")
        XCTAssertEqual(result.errorMessage, "device unavailable")
    }

    func testEngineRunCommandReturnsFailureInsteadOfThrowing() async {
        let provider = FailingCommandProvider()
        let engine = Engine(
            settings: AppSettings(),
            providers: [provider],
            registerBuiltInProviders: false
        )

        let result = await engine.runCommand(
            provider: "demo",
            providerName: "Demo Provider",
            commandID: "demo.restart",
            commandLabel: "Restart"
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Restart failed for Demo Provider: device unavailable")

        let usage = await engine.usageSnapshots()
        XCTAssertEqual(usage["demo"]?.commandCount, 1)
        XCTAssertEqual(usage["demo"]?.failureCount, 1)
    }
}

private actor FailingCommandProvider: Provider {
    let id: ProviderID = "demo"
    let displayName = "Demo Provider"
    let pollInterval: TimeInterval = 10
    let commands = [CommandDescriptor(id: "demo.restart", label: "Restart")]

    func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        ProviderSnapshot(health: .unknown)
    }

    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        throw JSONRPCClientError.commandFailed("device unavailable")
    }
}
