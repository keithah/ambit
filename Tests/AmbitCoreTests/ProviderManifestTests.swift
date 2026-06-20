import XCTest
@testable import AmbitCore

final class ProviderManifestTests: XCTestCase {
    func testDecodesDeclarativeProviderManifest() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "demo.ping",
          "displayName": "Demo Ping",
          "pollInterval": 30,
          "endpoint": {
            "method": "GET",
            "url": "https://example.test/status"
          },
          "metrics": [
            {
              "id": "latency_ms",
              "label": "Latency",
              "value": { "type": "latency", "path": "latency.avg" }
            }
          ],
          "commands": [
            {
              "id": "demo.ping.refresh",
              "label": "Refresh",
              "requiresConfirmation": false,
              "parameters": [
                { "id": "host", "label": "Host", "kind": { "type": "text" } }
              ]
            }
          ]
        }
        """

        let manifest = try ProviderManifest.decode(Data(json.utf8))

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.id, "demo.ping")
        XCTAssertEqual(manifest.displayName, "Demo Ping")
        XCTAssertEqual(manifest.pollInterval, 30)
        XCTAssertEqual(manifest.endpoint.method, .get)
        XCTAssertEqual(manifest.metrics.first?.value.type, .latency)
        XCTAssertEqual(manifest.metrics.first?.value.path, "latency.avg")
        XCTAssertEqual(manifest.commands.first?.parameters.first?.kind, .text)
    }

    func testManifestValidationRejectsDuplicateIDs() throws {
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo",
            displayName: "Demo",
            pollInterval: 10,
            endpoint: ProviderManifest.Endpoint(method: .get, url: "https://example.test/status"),
            metrics: [
                ProviderManifest.MetricMapping(id: "latency", label: "Latency", value: .init(type: .latency, path: "a")),
                ProviderManifest.MetricMapping(id: "latency", label: "Latency 2", value: .init(type: .latency, path: "b"))
            ],
            commands: []
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? ProviderManifest.ValidationError, .duplicateMetricID("latency"))
        }
    }

    func testManifestCommandDescriptorProjectionMatchesProviderCommands() throws {
        let manifest = ProviderManifest(
            schemaVersion: 1,
            id: "demo",
            displayName: "Demo",
            pollInterval: 10,
            endpoint: ProviderManifest.Endpoint(method: .post, url: "https://example.test/actions"),
            metrics: [],
            commands: [
                ProviderManifest.Command(
                    id: "demo.setMode",
                    label: "Set Mode",
                    parameters: [
                        ProviderManifest.CommandParameter(id: "mode", label: "Mode", kind: .option(["fast", "quiet"]))
                    ],
                    requiresConfirmation: true
                )
            ]
        )

        XCTAssertEqual(manifest.commandDescriptors, [
            CommandDescriptor(
                id: "demo.setMode",
                label: "Set Mode",
                parameters: [CommandParameter(id: "mode", label: "Mode", kind: .option(["fast", "quiet"]))],
                requiresConfirmation: true
            )
        ])
    }

    func testManifestPackageLoadsManifestJSONFromDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambit-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestJSON = """
        {
          "schemaVersion": 1,
          "id": "demo.package",
          "displayName": "Packaged Demo",
          "pollInterval": 15,
          "endpoint": { "method": "GET", "url": "https://example.test/status" },
          "metrics": [
            { "id": "ok", "label": "OK", "value": { "type": "bool", "path": "ok" } }
          ],
          "commands": []
        }
        """
        try manifestJSON.data(using: .utf8)?.write(to: directory.appendingPathComponent("manifest.json"))

        let package = try ProviderManifestPackage.load(from: directory)

        XCTAssertEqual(package.directory, directory)
        XCTAssertEqual(package.manifest.id, "demo.package")
        XCTAssertEqual(package.manifest.displayName, "Packaged Demo")
    }

    func testExampleManifestPackageStaysValid() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let exampleDirectory = repoRoot
            .appendingPathComponent("Examples/provider-manifests/ping-demo", isDirectory: true)

        let package = try ProviderManifestPackage.load(from: exampleDirectory)

        XCTAssertEqual(package.manifest.id, "demo.ping")
        XCTAssertEqual(package.manifest.metrics.map(\.id), ["latency_ms", "packet_loss"])
        XCTAssertEqual(package.manifest.commandDescriptors.map(\.id), ["demo.ping.run"])
    }
}
