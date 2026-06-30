import XCTest
@testable import AmbitCore
@testable import AmbitMenuBar

@MainActor
final class AppIntentBridgeTests: XCTestCase {
    func testEntityDescriptorMapsToAppIntentEntityModelWithCurrentState() {
        let descriptor = EntityDescriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            unit: "%",
            metricID: "cpu_usage_percent"
        )
        let state = EntityState(id: descriptor.id, value: .number(42), availability: .online)

        let model = AmbitAppIntentEntityMapper.model(descriptor: descriptor, state: state)

        XCTAssertEqual(model.id, descriptor.id.rawValue)
        XCTAssertEqual(model.displayName, "CPU")
        XCTAssertEqual(model.currentValue, "42%")
        XCTAssertEqual(model.availability, .online)
    }

    func testCommandDescriptorMapsToIntentModelWithConfirmationFlag() {
        let descriptor = CommandDescriptor(
            id: "fixture.restart",
            label: "Restart",
            parameters: [
                CommandParameter(id: "force", label: "Force", kind: .bool)
            ],
            requiresConfirmation: true
        )

        let model = AmbitAppIntentCommandMapper.model(
            providerID: "fixture",
            providerName: "Fixture",
            command: descriptor
        )

        XCTAssertEqual(model.id, "fixture.fixture.restart")
        XCTAssertEqual(model.displayName, "Restart")
        XCTAssertEqual(model.providerName, "Fixture")
        XCTAssertTrue(model.requiresConfirmation)
        XCTAssertEqual(model.parameters.map(\.id), ["force"])
    }

    func testEntityQueryReturnsCurrentEntitiesFromFakeDataSource() async throws {
        let source = FakeAppIntentDataSource(
            entities: [
                AmbitAppIntentEntityModel(id: "a", displayName: "A", currentValue: "1", availability: .online),
                AmbitAppIntentEntityModel(id: "b", displayName: "B", currentValue: nil, availability: .unavailable)
            ]
        )
        let query = AmbitEntityQuery(dataSource: source)

        let all = try await query.entities(for: [])
        let selected = try await query.entities(for: ["b"])

        XCTAssertEqual(all.map(\.id), ["a", "b"])
        XCTAssertEqual(selected.map(\.id), ["b"])
    }

    func testActivateContextAndRefreshMonitorActionsInvokeDataSource() async throws {
        let source = FakeAppIntentDataSource()

        try await AmbitAppIntentActions.activateContext(id: "ctx.home", active: true, dataSource: source)
        try await AmbitAppIntentActions.refreshMonitor(id: "slot.ping", dataSource: source)

        XCTAssertEqual(source.activatedContexts, [ContextActivation(id: "ctx.home", active: true)])
        XCTAssertEqual(source.refreshedMonitorIDs, ["slot.ping"])
    }

    func testRunCommandActionInvokesDataSourceWithArguments() async throws {
        let source = FakeAppIntentDataSource()
        let command = AmbitAppIntentCommandModel(
            id: "fixture.fixture.restart",
            providerID: "fixture",
            providerName: "Fixture",
            commandID: "fixture.restart",
            displayName: "Restart",
            parameters: [],
            requiresConfirmation: true
        )

        try await AmbitAppIntentActions.runCommand(
            command,
            arguments: CommandArguments(values: ["force": .bool(true)]),
            dataSource: source
        )

        XCTAssertEqual(source.runCommands, [RunCommandRequest(command: command, arguments: CommandArguments(values: ["force": .bool(true)]))])
    }
}

private final class FakeAppIntentDataSource: AmbitAppIntentDataSource {
    var entities: [AmbitAppIntentEntityModel]
    var commands: [AmbitAppIntentCommandModel]
    var contexts: [ContextDeclaration]
    var activatedContexts: [ContextActivation] = []
    var refreshedMonitorIDs: [String?] = []
    var runCommands: [RunCommandRequest] = []

    init(
        entities: [AmbitAppIntentEntityModel] = [],
        commands: [AmbitAppIntentCommandModel] = [],
        contexts: [ContextDeclaration] = []
    ) {
        self.entities = entities
        self.commands = commands
        self.contexts = contexts
    }

    func currentEntities() async -> [AmbitAppIntentEntityModel] { entities }
    func currentCommands() async -> [AmbitAppIntentCommandModel] { commands }
    func currentContexts() async -> [ContextDeclaration] { contexts }

    func activateContext(id: ContextID, active: Bool) async throws {
        activatedContexts.append(ContextActivation(id: id, active: active))
    }

    func refreshMonitor(id: String?) async throws {
        refreshedMonitorIDs.append(id)
    }

    func runCommand(_ command: AmbitAppIntentCommandModel, arguments: CommandArguments) async throws {
        runCommands.append(RunCommandRequest(command: command, arguments: arguments))
    }
}
