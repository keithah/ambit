import Foundation
import Testing
@testable import AmbitKit

@Suite struct HistoryStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ambit-history-\(UUID().uuidString)")
    private var url: URL { folder.appendingPathComponent("samples.sqlite") }
    /// Recent enough that opening the store does not prune it.
    private let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 300).rounded(.down) * 300 - 3_600)

    @Test func samplesComeBackOldestFirstAndAFailureStaysAFailure() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(url: url)
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start + 10, failure: .timeout))
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start, latencyMs: 12.5))
        try await store.record(device: "b", series: "latency", sample: ProbeSample(date: start, latencyMs: 99))
        try await store.record(device: "a", series: "other", sample: ProbeSample(date: start, latencyMs: 98))

        let samples = try await store.samples(device: "a", series: "latency", since: start)
        #expect(samples.map(\.date) == [start, start + 10])
        #expect(samples.map(\.latencyMs) == [12.5, nil])
        #expect(try await store.samples(device: "a", series: "latency", since: start + 1).count == 1)
    }

    @Test func samplesSurviveReopening() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let store = try HistoryStore(url: url)
            try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start, latencyMs: 7))
        }
        let reopened = try HistoryStore(url: url)
        #expect(try await reopened.samples(device: "a", series: "latency", since: start).map(\.latencyMs) == [7])
    }

    @Test func openingDropsSamplesOlderThanADay() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Date().addingTimeInterval(-HistoryStore.keep - 60)
        do {
            let store = try HistoryStore(url: url)
            try await store.record(device: "a", series: "latency", sample: ProbeSample(date: old, latencyMs: 7))
            try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start, latencyMs: 8))
        }
        let reopened = try HistoryStore(url: url)
        #expect(try await reopened.samples(device: "a", series: "latency", since: .distantPast).map(\.latencyMs) == [8])
    }

    @Test func bucketsAverageTheAnswersAndCountTheFailures() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(url: url)
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start + 1, latencyMs: 10))
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start + 2, latencyMs: 30))
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start + 3, failure: .timeout))
        // The next stretch has no samples; the one after has only a failure.
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start + 601, failure: .timeout))

        let buckets = try await store.buckets(device: "a", series: "latency", since: start, seconds: 300)
        #expect(buckets == [
            HistoryBucket(start: start, averageMs: 20, failures: 1, count: 3),
            HistoryBucket(start: start + 600, averageMs: nil, failures: 1, count: 1),
        ])
    }

    @Test func removingADeviceLeavesTheOthers() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(url: url)
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start, latencyMs: 1))
        try await store.record(device: "b", series: "latency", sample: ProbeSample(date: start, latencyMs: 2))
        try await store.remove(device: "a")
        #expect(try await store.samples(device: "a", series: "latency", since: start).isEmpty)
        #expect(try await store.samples(device: "b", series: "latency", since: start).count == 1)
    }

    @Test func aLatencyThatIsNotANumberIsStoredAsNoReply() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(url: url)
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start, latencyMs: .infinity))
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start + 1, latencyMs: .nan))
        #expect(try await store.samples(device: "a", series: "latency", since: start).map(\.latencyMs) == [nil, nil])
    }

    @Test func aFileThatIsNotADatabaseIsReplaced() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        #expect(throws: HistoryError.self) { try HistoryStore(url: url) }
        let store = try HistoryStore.open(replacingIfUnusable: url)
        try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start, latencyMs: 3))
        #expect(try await store.samples(device: "a", series: "latency", since: start).count == 1)
    }

    @Test func aDatabaseThatCannotBeWrittenIsLeftAlone() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            let store = try HistoryStore(url: url)
            try await store.record(device: "a", series: "latency", sample: ProbeSample(date: start, latencyMs: 3))
        }
        // Fold the write-ahead log into the file, then make the file read-only.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        #expect(throws: HistoryError.self) { try HistoryStore.open(replacingIfUnusable: url) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aBucketIsAFailureOnTheGraphWhenHalfItsProbesGotNoReply() {
        let middle = start + 150
        #expect(HistoryBucket(start: start, averageMs: 20, failures: 1, count: 3).sample(at: middle) == ProbeSample(date: middle, latencyMs: 20))
        #expect(HistoryBucket(start: start, averageMs: 20, failures: 2, count: 4).sample(at: middle).succeeded == false)
        #expect(HistoryBucket(start: start, averageMs: nil, failures: 1, count: 1).sample(at: middle).succeeded == false)
    }

    @Test func aPauseStartsANewRun() {
        let samples = [0, 5, 10, 400, 405, 2_000].map { ProbeSample(date: start + $0, latencyMs: 1) }
        #expect(samples.runs(brokenBy: 60) == [0, 0, 0, 1, 1, 2])
        #expect([ProbeSample]().runs(brokenBy: 60).isEmpty)
    }
}
