import Foundation

public enum NotificationInterruptionLevel: String, Codable, Equatable, Sendable {
    case passive
    case active
    case timeSensitive
}

public enum NotifyLifecycle: String, Codable, Equatable, Sendable {
    case oneShot
    case boundToCondition

    public func phase(forActive active: Bool) -> AlertEventPhase {
        switch self {
        case .oneShot:
            return .active
        case .boundToCondition:
            return active ? .active : .recovered
        }
    }
}

public struct NotifySpec: Codable, Equatable, Sendable {
    public var titleTemplate: String
    public var bodyTemplate: String?
    public var level: NotificationInterruptionLevel
    public var lifecycle: NotifyLifecycle
    public var actions: [CommandInvocation]

    public init(
        titleTemplate: String,
        bodyTemplate: String? = nil,
        level: NotificationInterruptionLevel,
        lifecycle: NotifyLifecycle,
        actions: [CommandInvocation] = []
    ) {
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.level = level
        self.lifecycle = lifecycle
        self.actions = actions
    }
}

public enum SurfaceProperty: String, Codable, Equatable, Sendable {
    case icon
    case badge
    case color
    case visible
}

public struct SurfacePropertyAddress: Codable, Equatable, Hashable, Sendable {
    public var surfaceID: String
    public var itemID: String
    public var property: SurfaceProperty

    public init(surfaceID: String, itemID: String, property: SurfaceProperty) {
        self.surfaceID = surfaceID
        self.itemID = itemID
        self.property = property
    }
}

public struct SurfaceMutation: Codable, Equatable, Sendable {
    public var target: SurfacePropertyAddress
    public var set: ConditionValue

    public init(target: SurfacePropertyAddress, set: ConditionValue) {
        self.target = target
        self.set = set
    }
}

public struct CommandInvocation: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var commandID: String
    public var arguments: CommandArguments
    public var requiresConfirmation: Bool

    public init(
        providerID: ProviderID,
        commandID: String,
        arguments: CommandArguments = CommandArguments(),
        requiresConfirmation: Bool = false
    ) {
        self.providerID = providerID
        self.commandID = commandID
        self.arguments = arguments
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum Reaction: Codable, Equatable, Sendable {
    case notify(NotifySpec)
    case mutateSurface(SurfaceMutation)
    case runCommand(CommandInvocation)
    case applyContext(id: String, active: Bool)
}

public enum ReactionConfirmation: Equatable, Sendable {
    case notRequired
    case notConfirmed
    case confirmed
}

public enum ReactionExecutionResult: Equatable, Sendable {
    case ignored
    case notified(NotifySpec)
    case mutatedSurface(SurfaceMutation)
    case revertedSurface(SurfaceMutation)
    case requiresConfirmation(CommandInvocation)
    case ranCommand(CommandInvocation)
    case contextDeferred(String)
}

public struct SurfaceMutationState: Equatable, Sendable {
    private var values: [SurfacePropertyAddress: ConditionValue] = [:]

    public init() {}

    public mutating func apply(_ mutation: SurfaceMutation, isActive: Bool) {
        if isActive {
            values[mutation.target] = mutation.set
        } else {
            values[mutation.target] = nil
        }
    }

    public func value(for address: SurfacePropertyAddress) -> ConditionValue? {
        values[address]
    }
}

public struct ReactionExecutor: Sendable {
    public typealias CommandDispatcher = @Sendable (CommandInvocation) async throws -> Void

    private let commandDispatcher: CommandDispatcher?

    public init(commandDispatcher: CommandDispatcher? = nil) {
        self.commandDispatcher = commandDispatcher
    }

    public func execute(_ reaction: Reaction, confirmation: ReactionConfirmation) async throws -> ReactionExecutionResult {
        switch reaction {
        case .notify(let spec):
            return .notified(spec)
        case .mutateSurface(let mutation):
            return .mutatedSurface(mutation)
        case .runCommand(let invocation):
            return try await run(invocation, confirmation: confirmation)
        case .applyContext(let id, _):
            return .contextDeferred(id)
        }
    }

    public func invokeNotificationAction(
        _ invocation: CommandInvocation,
        confirmation: ReactionConfirmation
    ) async throws -> ReactionExecutionResult {
        try await run(invocation, confirmation: confirmation)
    }

    private func run(_ invocation: CommandInvocation, confirmation: ReactionConfirmation) async throws -> ReactionExecutionResult {
        if invocation.requiresConfirmation && confirmation != .confirmed {
            return .requiresConfirmation(invocation)
        }
        try await commandDispatcher?(invocation)
        return .ranCommand(invocation)
    }
}

public extension AlertKindDeclaration {
    var reactions: [Reaction] {
        [
            .notify(NotifySpec(
                titleTemplate: titleTemplate,
                bodyTemplate: messageTemplate,
                level: severity >= .down ? .timeSensitive : .active,
                lifecycle: recovery == nil ? .oneShot : .boundToCondition,
                actions: []
            ))
        ]
    }
}
