import Foundation
import XCTest
@testable import AmbitMenuBar

final class AppLifecycleServiceTests: XCTestCase {
    func testFileAppInstanceLockPreventsSecondOwnerUntilReleased() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambit-lock-\(UUID().uuidString)")
        let first = FileAppInstanceLock(lockFileURL: url)
        let second = FileAppInstanceLock(lockFileURL: url)

        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())

        first.release()
        XCTAssertTrue(second.acquire())
        second.release()
    }

    @MainActor
    func testStartAtLoginCoordinatorRollsBackPreferenceWhenManagerFails() async {
        let manager = FakeLoginItemManager(enabled: false, result: .failure(TestError.failure))
        let coordinator = StartAtLoginCoordinator(manager: manager)

        let result = await coordinator.setEnabled(true)

        XCTAssertEqual(result, .failed(rolledBackTo: false, message: "failure"))
        XCTAssertEqual(manager.enabled, false)
    }

    @MainActor
    func testStartAtLoginCoordinatorAppliesPreferenceWhenManagerSucceeds() async {
        let manager = FakeLoginItemManager(enabled: false, result: .success(()))
        let coordinator = StartAtLoginCoordinator(manager: manager)

        let result = await coordinator.setEnabled(true)

        XCTAssertEqual(result, .applied(true))
        XCTAssertEqual(manager.enabled, true)
    }
}

private enum TestError: Error, CustomStringConvertible {
    case failure
    var description: String { "failure" }
}

@MainActor
private final class FakeLoginItemManager: LoginItemManaging {
    var enabled: Bool
    var result: Result<Void, Error>

    init(enabled: Bool, result: Result<Void, Error>) {
        self.enabled = enabled
        self.result = result
    }

    func isEnabled() -> Bool { enabled }

    func setEnabled(_ enabled: Bool) throws {
        switch result {
        case .success:
            self.enabled = enabled
        case .failure(let error):
            throw error
        }
    }
}
