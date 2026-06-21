import Foundation

public enum CommandArgumentBuilder {
    public static func validate(parameters: [CommandParameter], rawValues: [String: String]) -> String? {
        for parameter in parameters {
            let rawValue = rawValues[parameter.id] ?? defaultValue(for: parameter)
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch parameter.kind {
            case .text:
                if trimmedValue.isEmpty {
                    return "\(parameter.label) is required."
                }
            case .number:
                if trimmedValue.isEmpty || Double(trimmedValue) == nil {
                    return "\(parameter.label) must be a number."
                }
            case .option(let options):
                if !options.isEmpty && !options.contains(rawValue) {
                    return "\(parameter.label) must be one of \(options.joined(separator: ", "))."
                }
            case .bool:
                break
            }
        }
        return nil
    }

    public static func arguments(parameters: [CommandParameter], rawValues: [String: String]) -> CommandArguments {
        var values: [String: JSONValue] = [:]
        for parameter in parameters {
            let rawValue = rawValues[parameter.id] ?? defaultValue(for: parameter)
            switch parameter.kind {
            case .text:
                values[parameter.id] = .string(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
            case .option:
                values[parameter.id] = .string(rawValue)
            case .bool:
                values[parameter.id] = .bool(rawValue == "true")
            case .number:
                values[parameter.id] = .number(Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            }
        }
        return CommandArguments(values: values)
    }

    public static func defaultValue(for parameter: CommandParameter) -> String {
        switch parameter.kind {
        case .text, .number:
            return ""
        case .bool:
            return "false"
        case .option(let options):
            return options.first ?? ""
        }
    }
}
