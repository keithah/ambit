import XCTest
@testable import AmbitCore

final class SystemMetricsReaderTests: XCTestCase {
    func testFakeSystemMetricsReaderReturnsCannedSnapshotExactly() async throws {
        let snapshot = Self.snapshot()
        let reader = FakeSystemMetricsReader(snapshot: snapshot)

        let result = try await reader.snapshot()

        XCTAssertEqual(result, snapshot)
    }

    func testSystemMetricsSnapshotCodableRoundTrips() throws {
        let snapshot = Self.snapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SystemMetricsSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }

    #if canImport(Darwin)
    func testDarwinReaderReturnsReasonableCPUShape() async throws {
        let snapshot = try await DarwinSystemMetricsReader().snapshot()

        let total = snapshot.cpu.userPercent + snapshot.cpu.systemPercent + snapshot.cpu.idlePercent
        XCTAssertEqual(total, 100, accuracy: 1.0)
        XCTAssertGreaterThan(snapshot.cpu.coreCount, 0)
    }

    func testDarwinReaderReturnsReasonableMemoryShape() async throws {
        let snapshot = try await DarwinSystemMetricsReader().snapshot()

        XCTAssertGreaterThan(snapshot.memory.totalBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.memory.usedBytes, snapshot.memory.totalBytes)
        if let pressurePercent = snapshot.memory.pressurePercent {
            XCTAssertGreaterThanOrEqual(pressurePercent, 0)
            XCTAssertLessThanOrEqual(pressurePercent, 100)
        }
        if let appActiveBytes = snapshot.memory.appActiveBytes {
            XCTAssertLessThanOrEqual(appActiveBytes, snapshot.memory.totalBytes)
        }
        if let freeBytes = snapshot.memory.freeBytes {
            XCTAssertLessThanOrEqual(freeBytes, snapshot.memory.totalBytes)
        }
    }

    func testDarwinReaderReturnsAtLeastOneNonLoopbackVolume() async throws {
        let snapshot = try await DarwinSystemMetricsReader().snapshot()

        XCTAssertTrue(snapshot.diskVolumes.contains { !$0.mountPath.isEmpty && $0.totalBytes > 0 })
    }

    func testDarwinReaderBatteryProbeReturnsWithoutThrowing() async throws {
        let snapshot = try await DarwinSystemMetricsReader().snapshot()

        XCTAssertGreaterThanOrEqual(snapshot.battery.percent, 0)
        XCTAssertLessThanOrEqual(snapshot.battery.percent, 100)
    }

    func testDarwinReaderReturnsNonNegativeUptime() async throws {
        let snapshot = try await DarwinSystemMetricsReader().snapshot()

        XCTAssertGreaterThanOrEqual(snapshot.uptimeSeconds ?? -1, 0)
    }
    #endif

    private static func snapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(
                userPercent: 12.5,
                systemPercent: 7.5,
                idlePercent: 80,
                coreCount: 10,
                loadAverages: [1.2, 1.4, 1.6]
            ),
            memory: MemoryMetrics(
                usedBytes: 8_000_000_000,
                wiredBytes: 2_000_000_000,
                compressedBytes: 1_000_000_000,
                totalBytes: 16_000_000_000,
                pressurePercent: 31.25,
                appActiveBytes: 4_000_000_000,
                freeBytes: 8_000_000_000
            ),
            diskVolumes: [
                DiskVolumeMetrics(
                    mountPath: "/",
                    totalBytes: 1_000_000_000_000,
                    availableBytes: 500_000_000_000,
                    volumeName: "Macintosh HD"
                )
            ],
            networkCounters: [
                NetworkCounterMetrics(
                    interfaceName: "en0",
                    bytesIn: 123,
                    bytesOut: 456,
                    isLoopback: false
                )
            ],
            battery: BatteryMetrics(percent: 88, isCharging: true, isPresent: true),
            processes: [],
            uptimeSeconds: 12_345
        )
    }
}

private struct FakeSystemMetricsReader: SystemMetricsReading {
    var snapshot: SystemMetricsSnapshot

    func snapshot() async throws -> SystemMetricsSnapshot {
        snapshot
    }
}
