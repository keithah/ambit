import XCTest
@testable import AmbitCore

final class SystemTableProviderTests: XCTestCase {
    func testStorageProviderMapsDiskVolumesToTableValue() async {
        let provider = SystemStorageProvider(reader: FakeSystemTableReader(snapshot: Self.snapshot()))

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        guard case .table(let table) = snapshot.metricValue("volumes") else {
            return XCTFail("Expected volumes table")
        }
        XCTAssertEqual(table.columns.map(\.id), ["volume", "mount", "used", "available", "total"])
        XCTAssertEqual(table.rows.map(\.id), ["/", "/Volumes/Data"])
        XCTAssertEqual(table.rows[0].cells["volume"], .text("Macintosh HD"))
        XCTAssertEqual(table.rows[0].cells["mount"], .text("/"))
        XCTAssertEqual(table.rows[0].cells["used"], .number(60, unit: "B"))
        XCTAssertEqual(table.rows[0].cells["available"], .number(40, unit: "B"))
        XCTAssertEqual(table.rows[0].cells["total"], .number(100, unit: "B"))
    }

    func testProcessParserSkipsMalformedLinesGracefully() {
        let output = """
        PID %CPU RSS COMM
        123 20.5 1048576 WindowServer
        nope 12.0 99 BadPID
        456 not-a-number 2048 BadCPU
        789 2.5 4096 loginwindow
        """

        let rows = PSProcessParser.parse(output)

        XCTAssertEqual(rows.map(\.rowID), ["123:WindowServer", "789:loginwindow"])
        XCTAssertEqual(rows[0].pid, 123)
        XCTAssertEqual(rows[0].name, "WindowServer")
        XCTAssertEqual(rows[0].cpuPercent, 20.5)
        XCTAssertEqual(rows[0].memoryBytes, 1_073_741_824)
    }

    func testProcessParserUsesExecutableBasenameForDisplayName() {
        let output = """
        PID %CPU RSS COMM
        321 12.0 2048 /Applications/Ambit.app/Contents/MacOS/Ambit
        654 2.5 1024 /usr/libexec/trustd
        """

        let rows = PSProcessParser.parse(output)

        XCTAssertEqual(rows.map(\.name), ["Ambit", "trustd"])
        XCTAssertEqual(rows.map(\.rowID), ["321:Ambit", "654:trustd"])
    }

    func testProcessProviderBuildsTopCPUAndMemoryTablesFromFakeRunner() async {
        let runner = FakeProcessRunner(output: """
        PID %CPU RSS COMM
        100 5.0 1048576 LowCPU
        200 42.5 2048 /Applications/Ambit.app/Contents/MacOS/HotCPU
        300 1.0 4096000 BigMemory
        """)
        let provider = SystemProcessProvider(processRunner: runner, limit: 2)

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        guard case .table(let cpuTable) = snapshot.metricValue("top_cpu") else {
            return XCTFail("Expected top_cpu table")
        }
        guard case .table(let memoryTable) = snapshot.metricValue("top_memory") else {
            return XCTFail("Expected top_memory table")
        }
        XCTAssertEqual(cpuTable.columns.map(\.id), ["pid", "name", "cpu", "memory"])
        XCTAssertEqual(cpuTable.rows.map(\.id), ["200:HotCPU", "100:LowCPU"])
        XCTAssertEqual(cpuTable.rows[0].cells["name"], .text("HotCPU"))
        XCTAssertEqual(cpuTable.rows[0].cells["cpu"], .number(42.5, unit: "%"))
        XCTAssertEqual(memoryTable.rows.map(\.id), ["300:BigMemory", "100:LowCPU"])
        XCTAssertEqual(memoryTable.rows[0].cells["memory"], .number(4_194_304_000, unit: "B"))
    }

    func testSystemProcessRunnerDrainsLargeStdoutBeforeTermination() async throws {
        let runner = SystemProcessRunner()
        let script = """
        i=0
        while [ $i -lt 10000 ]; do
          echo '1234567890123456789012345678901234567890'
          i=$((i + 1))
        done
        """

        let result = try await runner.run(executable: "/bin/sh", arguments: ["-c", script], timeout: 5)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.count, 300_000)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testSystemTablesRouteThroughGenericSections() {
        let descriptors = SystemStorageProvider(reader: FakeSystemTableReader(snapshot: Self.snapshot())).entityDescriptors()
            + SystemProcessProvider(processRunner: FakeProcessRunner(output: ""), limit: 2).entityDescriptors()

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["CPU", "Memory", "Disk"])
        XCTAssertTrue(plan.cards.flatMap(\.children).allSatisfy { $0.kind == .statTable })
    }

    func testSystemIntegrationReturnsOverviewStorageAndProcessProviders() {
        let integration = SystemIntegration(
            reader: FakeSystemTableReader(snapshot: Self.snapshot()),
            processRunner: FakeProcessRunner(output: "")
        )

        let providers = integration.makeProviders(instance: IntegrationInstanceRecord(
            id: IntegrationInstanceIDs.systemLocal,
            integrationID: IntegrationIDs.system,
            displayName: "System",
            enabled: true,
            origin: .builtIn
        ))

        XCTAssertEqual(providers.map(\.id), [
            ProviderIDs.systemOverview,
            ProviderIDs.systemStorage,
            ProviderIDs.systemProcesses,
            ProviderIDs.systemNetwork,
            ProviderIDs.systemSensors,
            ProviderIDs.systemFans,
            ProviderIDs.systemCalendar,
            ProviderIDs.systemLocation,
            ProviderIDs.systemFocus
        ])
    }

    func testOverviewProviderStillEmitsP64Metrics() async {
        let provider = SystemOverviewProvider(reader: FakeSystemTableReader(snapshot: Self.snapshot()))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.metricValue("cpu_usage_percent"), .percent(20))
        XCTAssertEqual(snapshot.metricValue("memory_used_percent"), .percent(50))
    }

    private static func snapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 12.5, systemPercent: 7.5, idlePercent: 80, coreCount: 10, loadAverages: [1.2]),
            memory: MemoryMetrics(usedBytes: 8_000_000_000, wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000, totalBytes: 16_000_000_000),
            diskVolumes: [
                DiskVolumeMetrics(mountPath: "/", totalBytes: 100, availableBytes: 40, volumeName: "Macintosh HD"),
                DiskVolumeMetrics(mountPath: "/Volumes/Data", totalBytes: 200, availableBytes: 125, volumeName: "Data")
            ],
            battery: BatteryMetrics(percent: 88, isCharging: true, isPresent: true)
        )
    }
}

private struct FakeSystemTableReader: SystemMetricsReading {
    var snapshot: SystemMetricsSnapshot
    func snapshot() async throws -> SystemMetricsSnapshot { snapshot }
}

private struct FakeProcessRunner: ProcessRunner {
    var output: String
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}
