import Foundation
import ServiceManagement
import Darwin

final class FileAppInstanceLock: @unchecked Sendable {
    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1

    init(lockFileURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("com.hadm.ambit.lock")) {
        self.lockFileURL = lockFileURL
    }

    func acquire() -> Bool {
        if fileDescriptor >= 0 { return true }
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        fileDescriptor = fd
        return true
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}

@MainActor
protocol LoginItemManaging: AnyObject {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class MacLoginItemManager: LoginItemManaging {
    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum StartAtLoginUpdateResult: Equatable, Sendable {
    case applied(Bool)
    case failed(rolledBackTo: Bool, message: String)
}

@MainActor
final class StartAtLoginCoordinator {
    private let manager: any LoginItemManaging

    init(manager: any LoginItemManaging = MacLoginItemManager()) {
        self.manager = manager
    }

    func isEnabled() -> Bool {
        manager.isEnabled()
    }

    func setEnabled(_ enabled: Bool) async -> StartAtLoginUpdateResult {
        let previous = manager.isEnabled()
        do {
            try manager.setEnabled(enabled)
            return .applied(enabled)
        } catch {
            try? manager.setEnabled(previous)
            return .failed(rolledBackTo: previous, message: String(describing: error))
        }
    }
}
