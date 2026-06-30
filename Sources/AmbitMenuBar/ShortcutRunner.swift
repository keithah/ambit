import AmbitCore
import Foundation

enum MacShortcutRunnerError: Error, Equatable {
    case shortcutCommandFailed(Int32)
}

struct MacShortcutRunner: Sendable {
    var executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        self.executableURL = executableURL
    }

    func run(_ invocation: ShortcutInvocation) async throws {
        try await Task.detached(priority: .utility) {
            var temporaryInputURL: URL?
            let process = Process()
            process.executableURL = executableURL
            var arguments = ["run", invocation.name]
            if !invocation.arguments.values.isEmpty {
                let inputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ambit-shortcut-\(UUID().uuidString).json")
                let data = try JSONEncoder().encode(invocation.arguments)
                try data.write(to: inputURL, options: [.atomic])
                temporaryInputURL = inputURL
                arguments += ["--input-path", inputURL.path]
            }
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            if let temporaryInputURL {
                try? FileManager.default.removeItem(at: temporaryInputURL)
            }
            guard process.terminationStatus == 0 else {
                throw MacShortcutRunnerError.shortcutCommandFailed(process.terminationStatus)
            }
        }.value
    }
}

