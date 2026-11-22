import Foundation
import Testing
@testable import AmbitKit

@Suite struct DeviceHealthTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func startsLoadingAndStaysSoUntilThreeMissedPolls() {
        var tracker = DeviceHealthTracker()
        #expect(tracker.condition == .loading)
        tracker.failed(.noReply, at: start)
        tracker.failed(.noReply, at: start)
        #expect(tracker.condition == .loading)
        tracker.failed(.noReply, at: start)
        #expect(tracker.condition == .unreachable)
    }

    @Test func aMissedPollMakesAnOnlineDeviceStaleNotUnreachable() {
        var tracker = DeviceHealthTracker()
        tracker.succeeded(at: start)
        #expect(tracker.condition == .online)
        tracker.failed(.noReply, at: start + 5)
        #expect(tracker.condition == .stale(lastSeen: start))
        tracker.failed(.noReply, at: start + 10)
        #expect(tracker.condition == .stale(lastSeen: start))
        tracker.failed(.noReply, at: start + 15)
        #expect(tracker.condition == .unreachable)
        tracker.succeeded(at: start + 20)
        #expect(tracker.condition == .online)
        tracker.failed(.noReply, at: start + 25)
        #expect(tracker.condition == .stale(lastSeen: start + 20))
    }

    @Test func passwordProblemsShowAtOnce() {
        var tracker = DeviceHealthTracker()
        tracker.failed(.passwordNeeded, at: start)
        #expect(tracker.condition == .passwordNeeded)
        tracker.failed(.wrongPassword, at: start)
        #expect(tracker.condition == .wrongPassword)
        tracker.failed(.unexpectedReply, at: start)
        #expect(tracker.condition == .unexpectedReply)
    }

    @Test func aDeviceThatAnsweredWithAnErrorAndThenWentQuietIsUnreachable() {
        var tracker = DeviceHealthTracker()
        tracker.failed(.wrongPassword, at: start)
        tracker.failed(.noReply, at: start + 5)
        #expect(tracker.condition == .unreachable)
    }

    @Test func aLockoutKeepsItsFirstDeadline() {
        var tracker = DeviceHealthTracker()
        tracker.failed(.lockedOut(seconds: 290), at: start)
        #expect(tracker.condition == .lockedOut(until: start + 290))
        // Later polls report the time left; the deadline does not move.
        tracker.failed(.lockedOut(seconds: 280), at: start + 10)
        #expect(tracker.condition == .lockedOut(until: start + 290))
        // After the deadline a lockout is a new one.
        tracker.failed(.lockedOut(seconds: nil), at: start + 300)
        #expect(tracker.condition == .lockedOut(until: start + 300 + DeviceHealthTracker.defaultLockout))
        tracker.failed(.lockedOut(seconds: 0), at: start + 1_000)
        #expect(tracker.condition == .lockedOut(until: start + 1_000 + DeviceHealthTracker.defaultLockout))
    }

    @Test func errorsMapToFailures() {
        #expect(DeviceFailure(starlink: StarlinkError.timedOut) == .noReply)
        #expect(DeviceFailure(starlink: URLError(.cannotConnectToHost)) == .noReply)
        #expect(DeviceFailure(starlink: StarlinkError.http(500)) == .unexpectedReply)
        #expect(DeviceFailure(starlink: StarlinkError.unexpectedResponse) == .unexpectedReply)
        #expect(DeviceFailure(glinet: GLiNetError.timedOut) == .noReply)
        #expect(DeviceFailure(glinet: URLError(.networkConnectionLost)) == .noReply)
        #expect(DeviceFailure(glinet: GLiNetError.noPassword) == .passwordNeeded)
        #expect(DeviceFailure(glinet: GLiNetError.wrongPassword) == .wrongPassword)
        #expect(DeviceFailure(glinet: GLiNetError.lockedOut(seconds: 12)) == .lockedOut(seconds: 12))
        #expect(DeviceFailure(glinet: GLiNetError.accessDenied) == .unexpectedReply)
        #expect(DeviceFailure(glinet: GLiNetError.http(404)) == .unexpectedReply)
    }
}

@Suite struct DeviceListFileTests {
    private func temporaryFile() -> DeviceListFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ambit-tests-\(UUID().uuidString)")
        return DeviceListFile(url: folder.appendingPathComponent("devices.json"))
    }

    @Test func aMissingFileIsAnEmptyList() {
        #expect(temporaryFile().load() == [])
    }

    @Test func savesAndLoadsDevices() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let devices = [
            SavedDevice(kind: .starlink, name: "Starlink", host: "192.168.100.1"),
            SavedDevice(kind: .glinet, name: "Router", host: "192.168.8.1"),
        ]
        try file.save(devices)
        #expect(file.load() == devices)
    }

    @Test func anUnreadableFileIsSetAsideNotLost() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        #expect(file.load() == [])
        let aside = file.url.appendingPathExtension("unreadable")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}
