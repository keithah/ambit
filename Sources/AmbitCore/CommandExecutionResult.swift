import Foundation

public enum CommandExecutionStatus: Equatable, Sendable {
    case succeeded
    case failed
}

public struct CommandExecutionResult: Equatable, Sendable {
    public var providerID: ProviderID
    public var providerName: String
    public var commandID: String
    public var commandLabel: String
    public var status: CommandExecutionStatus
    public var message: String
    public var errorMessage: String?

    public init(
        providerID: ProviderID,
        providerName: String,
        commandID: String,
        commandLabel: String,
        status: CommandExecutionStatus,
        message: String,
        errorMessage: String? = nil
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.commandID = commandID
        self.commandLabel = commandLabel
        self.status = status
        self.message = message
        self.errorMessage = errorMessage.map { ProviderDisplayText.singleLine($0) }
    }

    public static func success(
        providerID: ProviderID,
        providerName: String,
        commandID: String,
        commandLabel: String
    ) -> CommandExecutionResult {
        CommandExecutionResult(
            providerID: providerID,
            providerName: providerName,
            commandID: commandID,
            commandLabel: commandLabel,
            status: .succeeded,
            message: "\(commandLabel) sent to \(providerName)."
        )
    }

    public static func failure(
        providerID: ProviderID,
        providerName: String,
        commandID: String,
        commandLabel: String,
        errorMessage: String
    ) -> CommandExecutionResult {
        let error = ProviderDisplayText.singleLine(errorMessage)
        return CommandExecutionResult(
            providerID: providerID,
            providerName: providerName,
            commandID: commandID,
            commandLabel: commandLabel,
            status: .failed,
            message: "\(commandLabel) failed for \(providerName): \(error)",
            errorMessage: error
        )
    }
}
