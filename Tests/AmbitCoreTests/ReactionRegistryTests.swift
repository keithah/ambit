import XCTest
@testable import AmbitCore

final class ReactionRegistryTests: XCTestCase {
    func testAlertKindCompilesToNotifyReactionWithCurrentNotificationCopy() {
        let declaration = AlertKindDeclaration(
            id: "fixture.down",
            titleTemplate: "{hostName} is down",
            messageTemplate: "No response from {hostName}.",
            severity: .critical,
            defaultEnabled: true,
            target: .entity("fixture/status"),
            trigger: .healthTransition(to: .down),
            recovery: AlertRecoveryDeclaration(titleTemplate: "{hostName} recovered", messageTemplate: "{hostName} is reachable again."),
            cooldown: 60
        )

        XCTAssertEqual(declaration.reactions, [
            .notify(NotifySpec(
                titleTemplate: "{hostName} is down",
                bodyTemplate: "No response from {hostName}.",
                level: .timeSensitive,
                lifecycle: .boundToCondition,
                actions: []
            ))
        ])

        let active = AlertEvent(
            ruleID: "fixture.down.host",
            providerID: "fixture",
            target: .entity("fixture/status"),
            title: "Fixture is down",
            message: "No response from Fixture.",
            severity: .critical
        )
        let recovered = AlertEvent(
            ruleID: "fixture.down.recovered.host",
            providerID: "fixture",
            target: .entity("fixture/status"),
            phase: .recovered,
            title: "Fixture recovered",
            message: "Fixture is reachable again.",
            severity: .info
        )

        XCTAssertEqual(NotifyLifecycle.boundToCondition.phase(forActive: true), active.phase)
        XCTAssertEqual(NotifyLifecycle.boundToCondition.phase(forActive: false), recovered.phase)
    }

    func testReactionCodableRoundTripsIncludingApplyContextStub() throws {
        let reactions: [Reaction] = [
            .notify(NotifySpec(titleTemplate: "Rain", bodyTemplate: "Bring a jacket", level: .active, lifecycle: .oneShot)),
            .mutateSurface(SurfaceMutation(
                target: SurfacePropertyAddress(surfaceID: "menubar", itemID: "weather", property: .icon),
                set: .string("cloud-rain")
            )),
            .runCommand(CommandInvocation(providerID: "fixture", commandID: "fixture.close", arguments: CommandArguments(values: ["force": .bool(true)]))),
            .applyContext(id: "home", active: true)
        ]

        let data = try JSONEncoder().encode(reactions)
        let decoded = try JSONDecoder().decode([Reaction].self, from: data)

        XCTAssertEqual(decoded, reactions)
    }

    func testRunCommandDispatchesThroughProviderAndRequiresConfirmation() async throws {
        let provider = RecordingReactionProvider(commands: [
            CommandDescriptor(id: "fixture.close", label: "Close", requiresConfirmation: true)
        ])
        let executor = ReactionExecutor(commandDispatcher: provider.dispatch)
        let invocation = CommandInvocation(
            providerID: provider.id,
            commandID: "fixture.close",
            arguments: CommandArguments(values: ["force": .bool(true)]),
            requiresConfirmation: true
        )

        let blocked = try await executor.execute(.runCommand(invocation), confirmation: .notConfirmed)
        let ran = try await executor.execute(.runCommand(invocation), confirmation: .confirmed)
        let calls = await provider.calls()

        XCTAssertEqual(blocked, .requiresConfirmation(invocation))
        XCTAssertEqual(ran, .ranCommand(invocation))
        XCTAssertEqual(calls, [invocation])
    }

    func testNotificationActionInvokesCommandThroughExecutor() async throws {
        let provider = RecordingReactionProvider(commands: [
            CommandDescriptor(id: "fixture.test", label: "Test")
        ])
        let invocation = CommandInvocation(providerID: provider.id, commandID: "fixture.test")
        let executor = ReactionExecutor(commandDispatcher: provider.dispatch)
        let result = try await executor.invokeNotificationAction(invocation, confirmation: .notRequired)
        let calls = await provider.calls()

        XCTAssertEqual(result, .ranCommand(invocation))
        XCTAssertEqual(calls, [invocation])
    }

    func testMutateSurfaceAppliesAndRevertsProperty() {
        let mutation = SurfaceMutation(
            target: SurfacePropertyAddress(surfaceID: "menubar", itemID: "weather", property: .badge),
            set: .string("rain")
        )
        var state = SurfaceMutationState()

        state.apply(mutation, isActive: true)
        XCTAssertEqual(state.value(for: mutation.target), .string("rain"))

        state.apply(mutation, isActive: false)
        XCTAssertNil(state.value(for: mutation.target))
    }

    func testApplyContextExecutorReturnsAppliedState() async throws {
        let executor = ReactionExecutor()
        let result = try await executor.execute(.applyContext(id: "home", active: true), confirmation: .notRequired)

        XCTAssertEqual(result, .contextApplied("home", active: true))
    }
}

private actor RecordingReactionProvider {
    let id: ProviderID = "fixture"
    let commands: [CommandDescriptor]
    private var recorded: [CommandInvocation] = []

    init(commands: [CommandDescriptor]) {
        self.commands = commands
    }

    func dispatch(_ invocation: CommandInvocation) async throws {
        guard commands.contains(where: { $0.id == invocation.commandID }) else {
            throw JSONRPCClientError.commandFailed("unsupported")
        }
        recorded.append(invocation)
    }

    func calls() -> [CommandInvocation] {
        recorded
    }
}
