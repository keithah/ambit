import Foundation
import AmbitCore

public struct AmbitAppIntentEntityModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var currentValue: String?
    public var availability: Availability

    public init(id: String, displayName: String, currentValue: String?, availability: Availability) {
        self.id = id
        self.displayName = displayName
        self.currentValue = currentValue
        self.availability = availability
    }
}

public struct AmbitAppIntentCommandParameterModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var kindDescription: String

    public init(id: String, label: String, kindDescription: String) {
        self.id = id
        self.label = label
        self.kindDescription = kindDescription
    }
}

public struct AmbitAppIntentCommandModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var providerName: String
    public var commandID: String
    public var displayName: String
    public var parameters: [AmbitAppIntentCommandParameterModel]
    public var requiresConfirmation: Bool

    public init(
        id: String,
        providerID: ProviderID,
        providerName: String,
        commandID: String,
        displayName: String,
        parameters: [AmbitAppIntentCommandParameterModel],
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.commandID = commandID
        self.displayName = displayName
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ContextActivation: Equatable, Sendable {
    public var id: ContextID
    public var active: Bool

    public init(id: ContextID, active: Bool) {
        self.id = id
        self.active = active
    }
}

public struct RunCommandRequest: Equatable, Sendable {
    public var command: AmbitAppIntentCommandModel
    public var arguments: CommandArguments

    public init(command: AmbitAppIntentCommandModel, arguments: CommandArguments) {
        self.command = command
        self.arguments = arguments
    }
}

@MainActor
public protocol AmbitAppIntentDataSource: AnyObject, Sendable {
    func currentEntities() async -> [AmbitAppIntentEntityModel]
    func currentCommands() async -> [AmbitAppIntentCommandModel]
    func currentContexts() async -> [ContextDeclaration]
    func activateContext(id: ContextID, active: Bool) async throws
    func refreshMonitor(id: String?) async throws
    func runCommand(_ command: AmbitAppIntentCommandModel, arguments: CommandArguments) async throws
}

public enum AmbitAppIntentEntityMapper {
    public static func model(descriptor: EntityDescriptor, state: EntityState?) -> AmbitAppIntentEntityModel {
        AmbitAppIntentEntityModel(
            id: descriptor.id.rawValue,
            displayName: descriptor.name,
            currentValue: state.map { EntityReadout.make(descriptor: descriptor, state: $0).text },
            availability: state?.availability ?? .unavailable
        )
    }
}

public enum AmbitAppIntentCommandMapper {
    public static func model(providerID: ProviderID, providerName: String, command: CommandDescriptor) -> AmbitAppIntentCommandModel {
        AmbitAppIntentCommandModel(
            id: "\(providerID).\(command.id)",
            providerID: providerID,
            providerName: providerName,
            commandID: command.id,
            displayName: command.label,
            parameters: command.parameters.map { parameter in
                AmbitAppIntentCommandParameterModel(
                    id: parameter.id,
                    label: parameter.label,
                    kindDescription: description(for: parameter.kind)
                )
            },
            requiresConfirmation: command.requiresConfirmation
        )
    }

    private static func description(for kind: CommandParameterKind) -> String {
        switch kind {
        case .bool: return "Boolean"
        case .number: return "Number"
        case .text: return "Text"
        case .option(let values): return "Options: \(values.joined(separator: ", "))"
        }
    }
}

@MainActor
public struct AmbitEntityQuery {
    private let dataSource: any AmbitAppIntentDataSource

    public init(dataSource: any AmbitAppIntentDataSource) {
        self.dataSource = dataSource
    }

    public func entities(for identifiers: [String]) async throws -> [AmbitAppIntentEntityModel] {
        let entities = await dataSource.currentEntities()
        guard !identifiers.isEmpty else { return entities }
        let wanted = Set(identifiers)
        return entities.filter { wanted.contains($0.id) }
    }
}

@MainActor
public enum AmbitAppIntentActions {
    public static func activateContext(id: ContextID, active: Bool, dataSource: any AmbitAppIntentDataSource) async throws {
        try await dataSource.activateContext(id: id, active: active)
    }

    public static func refreshMonitor(id: String?, dataSource: any AmbitAppIntentDataSource) async throws {
        try await dataSource.refreshMonitor(id: id)
    }

    public static func runCommand(
        _ command: AmbitAppIntentCommandModel,
        arguments: CommandArguments,
        dataSource: any AmbitAppIntentDataSource
    ) async throws {
        try await dataSource.runCommand(command, arguments: arguments)
    }
}

@MainActor
public final class AmbitAppIntentRegistry {
    public static let shared = AmbitAppIntentRegistry()
    public var dataSource: (any AmbitAppIntentDataSource)?
    private init() {}
}

@MainActor
final class StatusViewModelAppIntentDataSource: AmbitAppIntentDataSource, @unchecked Sendable {
    private weak var viewModel: StatusViewModel?

    init(viewModel: StatusViewModel) {
        self.viewModel = viewModel
    }

    func currentEntities() async -> [AmbitAppIntentEntityModel] {
        guard let viewModel else { return [] }
        let descriptors = await viewModel.engineEntityDescriptorsForAppIntents()
        let states = await viewModel.engineEntityStatesForAppIntents()
        return descriptors.map { descriptor in
            AmbitAppIntentEntityMapper.model(descriptor: descriptor, state: states[descriptor.id])
        }
    }

    func currentCommands() async -> [AmbitAppIntentCommandModel] {
        viewModel?.commandPalette.map { item in
            AmbitAppIntentCommandMapper.model(
                providerID: item.providerID,
                providerName: item.providerName,
                command: item.command
            )
        } ?? []
    }

    func currentContexts() async -> [ContextDeclaration] {
        viewModel?.contexts ?? []
    }

    func activateContext(id: ContextID, active: Bool) async throws {
        guard let viewModel else { return }
        viewModel.setContextManualOverrideForAppIntent(id: id, active: active)
    }

    func refreshMonitor(id: String?) async throws {
        await viewModel?.refresh()
    }

    func runCommand(_ command: AmbitAppIntentCommandModel, arguments: CommandArguments) async throws {
        await viewModel?.runCommandForAppIntent(command, arguments: arguments)
    }
}

#if canImport(AppIntents)
import AppIntents

@available(macOS 13.0, *)
public struct AmbitEntityAppEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Ambit Entity")
    public static let defaultQuery = AmbitEntityAppQuery()

    public var id: String
    public var displayName: String
    public var currentValue: String?
    public var availability: Availability

    public init(model: AmbitAppIntentEntityModel) {
        self.id = model.id
        self.displayName = model.displayName
        self.currentValue = model.currentValue
        self.availability = model.availability
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: currentValue.map { "\($0) · \(availability.rawValue)" } ?? "\(availability.rawValue)"
        )
    }
}

@available(macOS 13.0, *)
public struct AmbitEntityAppQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [AmbitEntityAppEntity] {
        guard let dataSource = await AmbitAppIntentRegistry.shared.dataSource else { return [] }
        let models = try await AmbitEntityQuery(dataSource: dataSource).entities(for: identifiers)
        return models.map(AmbitEntityAppEntity.init(model:))
    }

    public func suggestedEntities() async throws -> [AmbitEntityAppEntity] {
        try await entities(for: [])
    }
}

@available(macOS 13.0, *)
public struct RefreshAmbitMonitorIntent: AppIntent {
    public static let title: LocalizedStringResource = "Refresh Ambit"
    public static let description = IntentDescription("Refresh Ambit monitors.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let dataSource = await AmbitAppIntentRegistry.shared.dataSource else { return .result() }
        try await AmbitAppIntentActions.refreshMonitor(id: nil, dataSource: dataSource)
        return .result()
    }
}

@available(macOS 13.0, *)
public struct ActivateAmbitContextIntent: AppIntent {
    public static let title: LocalizedStringResource = "Activate Ambit Context"
    public static let description = IntentDescription("Activate an Ambit context.")
    public static let openAppWhenRun = false

    @Parameter(title: "Context ID")
    public var contextID: String

    public init() {
        self.contextID = ""
    }

    public init(contextID: String) {
        self.contextID = contextID
    }

    public func perform() async throws -> some IntentResult {
        guard let dataSource = await AmbitAppIntentRegistry.shared.dataSource else { return .result() }
        try await AmbitAppIntentActions.activateContext(id: ContextID(rawValue: contextID), active: true, dataSource: dataSource)
        return .result()
    }
}

@available(macOS 13.0, *)
public struct DeactivateAmbitContextIntent: AppIntent {
    public static let title: LocalizedStringResource = "Deactivate Ambit Context"
    public static let description = IntentDescription("Deactivate an Ambit context.")
    public static let openAppWhenRun = false

    @Parameter(title: "Context ID")
    public var contextID: String

    public init() {
        self.contextID = ""
    }

    public init(contextID: String) {
        self.contextID = contextID
    }

    public func perform() async throws -> some IntentResult {
        guard let dataSource = await AmbitAppIntentRegistry.shared.dataSource else { return .result() }
        try await AmbitAppIntentActions.activateContext(id: ContextID(rawValue: contextID), active: false, dataSource: dataSource)
        return .result()
    }
}

@available(macOS 13.0, *)
public struct RunAmbitCommandIntent: AppIntent {
    public static let title: LocalizedStringResource = "Run Ambit Command"
    public static let description = IntentDescription("Run a declared Ambit provider command.")
    public static let openAppWhenRun = false

    @Parameter(title: "Command ID")
    public var commandID: String

    public init() {
        self.commandID = ""
    }

    public init(commandID: String) {
        self.commandID = commandID
    }

    public func perform() async throws -> some IntentResult {
        guard let dataSource = await AmbitAppIntentRegistry.shared.dataSource else { return .result() }
        let commands = await dataSource.currentCommands()
        guard let command = commands.first(where: { $0.id == commandID }) else { return .result() }
        if command.requiresConfirmation {
            try await requestConfirmation()
        }
        try await AmbitAppIntentActions.runCommand(command, arguments: CommandArguments(), dataSource: dataSource)
        return .result()
    }
}

@available(macOS 13.0, *)
public struct AmbitAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAmbitMonitorIntent(),
            phrases: ["Refresh \(.applicationName)", "Update \(.applicationName)"],
            shortTitle: "Refresh",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: ActivateAmbitContextIntent(),
            phrases: ["Activate context in \(.applicationName)"],
            shortTitle: "Activate Context",
            systemImageName: "switch.2"
        )
    }
}
#endif
