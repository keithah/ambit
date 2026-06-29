import AppKit
import Foundation

protocol DiagnosticsLogService {
    var logURL: URL { get }
    func reveal() throws
    func copyPath() throws
    func clear() throws
}

struct AppKitDiagnosticsLogService: DiagnosticsLogService {
    let logURL: URL

    init(logURL: URL = AppKitDiagnosticsLogService.defaultLogURL()) {
        self.logURL = logURL
    }

    func reveal() throws {
        if FileManager.default.fileExists(atPath: logURL.path) == false {
            try ensureLogFile()
        }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    func copyPath() throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logURL.path, forType: .string)
    }

    func clear() throws {
        try ensureDirectory()
        try Data().write(to: logURL, options: .atomic)
    }

    private func ensureLogFile() throws {
        try ensureDirectory()
        if FileManager.default.fileExists(atPath: logURL.path) == false {
            try Data().write(to: logURL, options: .atomic)
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func defaultLogURL() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Ambit", isDirectory: true)
            .appendingPathComponent("ambit.log")
    }
}
