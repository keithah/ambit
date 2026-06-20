import Foundation

public enum ProviderDisplayText {
    public static func singleLine(_ value: String, maxLength: Int? = nil) -> String {
        var result = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if let maxLength, result.count > maxLength {
            let endIndex = result.index(result.startIndex, offsetBy: max(0, maxLength - 1))
            result = String(result[..<endIndex]) + "..."
        }
        return result
    }
}
