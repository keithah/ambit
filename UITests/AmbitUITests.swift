import XCTest

/// Drives the built app through its menu bar item. Each test starts the app with an empty data
/// folder of its own (`AMBIT_UI_TEST_DATA`), so the user's devices and history are never touched.
///
/// The tests only use a ping target at 127.0.0.1: it needs no device, no password and no network.
/// They assert nothing about the connection verdict, which depends on the machine's real network.
@MainActor
final class AmbitUITests: XCTestCase {
    private static let loopback = "127.0.0.1"

    private func newDataFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambit-uitests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Starts the app on `dataFolder` and opens its popover.
    private func launch(dataFolder: URL) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AMBIT_UI_TEST_DATA"] = dataFolder.path
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no menu bar item")
        item.click()
        // The item moves when its text changes width, so a click now and then lands beside it.
        if !app.buttons["Add device"].waitForExistence(timeout: 3) { item.click() }
        XCTAssertTrue(app.buttons["Add device"].waitForExistence(timeout: 5), "popover did not open")
        return app
    }

    /// Clicks until `result` shows. The popover lays itself out again whenever a reading arrives,
    /// so a control can move between the moment its place is read and the click.
    private func click(_ element: XCUIElement, shows result: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<4 {
            if element.exists { element.click() }
            if result.waitForExistence(timeout: 3) { return }
        }
        XCTFail("clicking \(element) did not show \(result)", file: file, line: line)
    }

    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// From the first page: fills in "Add by address" for a ping target and presses Add.
    private func addPingTarget(_ app: XCUIApplication, _ host: String, shows result: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let kind = app.radioButtons["Ping target"]
        click(app.buttons["Add device"], shows: kind, file: file, line: line)
        // The form moves down when the search for devices ends.
        XCTAssertTrue(app.buttons["Look again"].waitForExistence(timeout: 30), "the search for devices did not end", file: file, line: line)
        let address = app.textFields["Address"]
        click(kind, shows: app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Address or name'")).firstMatch, file: file, line: line)
        address.click()
        address.typeText(host)
        click(app.buttons["add-by-address"], shows: result, file: file, line: line)
    }

    func testMenuBarItemOpensThePopover() {
        let app = launch(dataFolder: newDataFolder())
        XCTAssertTrue(app.statusItems.firstMatch.label.hasPrefix("Ambit: "))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Router '")).firstMatch.exists)
        XCTAssertTrue(app.menuButtons["Settings"].exists)
        XCTAssertFalse(row(app, Self.loopback).exists, "the run did not start empty")
    }

    func testAddOpenAndRemoveAPingTarget() {
        let app = launch(dataFolder: newDataFolder())
        let target = row(app, Self.loopback)
        addPingTarget(app, Self.loopback, shows: target)
        // Loopback always answers; the row says so after the first ping.
        let answering = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Answering'")).firstMatch
        XCTAssertTrue(answering.waitForExistence(timeout: 15))

        let remove = app.buttons["Remove ping target"]
        click(target, shows: remove)
        XCTAssertTrue(app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "Latency to \(Self.loopback)")).firstMatch.exists)
        click(app.buttons["Back"], shows: app.buttons["Add device"])
        click(target, shows: remove)

        // Removing asks first; Cancel keeps the target.
        let cancel = app.buttons["Cancel"]
        click(remove, shows: cancel)
        XCTAssertTrue(app.staticTexts["Remove \(Self.loopback) from Ambit?"].exists)
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        click(remove, shows: cancel)
        click(remove, shows: app.buttons["Add device"])
        XCTAssertFalse(target.exists)
    }

    func testTheSameAddressCannotBeAddedTwice() {
        let app = launch(dataFolder: newDataFolder())
        addPingTarget(app, Self.loopback, shows: row(app, Self.loopback))
        addPingTarget(app, Self.loopback, shows: app.staticTexts["That device is already added."])
    }

    func testAnAddressThatCannotBePingedIsRefused() {
        let app = launch(dataFolder: newDataFolder())
        addPingTarget(app, "::1", shows: app.staticTexts["Ambit can ping a name or an IPv4 address, such as 9.9.9.9."])
    }

    func testAPingTargetIsStillThereAfterARestart() {
        let folder = newDataFolder()
        let first = launch(dataFolder: folder)
        addPingTarget(first, Self.loopback, shows: row(first, Self.loopback))
        first.terminate()

        let second = launch(dataFolder: folder)
        XCTAssertTrue(row(second, Self.loopback).waitForExistence(timeout: 5))
    }
}
