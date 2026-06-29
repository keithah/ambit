import XCTest

final class GenericMonitoringPingLeakGrepGateTests: XCTestCase {
    func testNoPingSpecificMonitoringIdentifiersOutsideAllowlist() throws {
        let root = try Self.repositoryRoot()
        let forbiddenPatterns = try [
            #"IntegrationIDs\.ping"#,
            #"Ping[A-Za-z]*Diagnos[A-Za-z]*"#,
            #"Ping[A-Za-z]*Alert[A-Za-z]*"#,
            #"NetworkTier"#,
            #"DiagnosisEntity"#
        ].map { pattern in try NSRegularExpression(pattern: pattern) }
        let files = try Self.swiftFiles(under: root)
            .filter { url in
                let path = url.path
                return path.contains("/Sources/AmbitCore/")
                    || path.contains("/Sources/AmbitMenuBar/")
            }
            .filter { !Self.isAllowlisted($0, root: root) }

        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for regex in forbiddenPatterns {
                for match in regex.matches(in: text, range: range) {
                    let matchRange = Range(match.range, in: text)!
                    let line = text[..<matchRange.lowerBound].filter { $0 == "\n" }.count + 1
                    let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                    let lineText = text.split(separator: "\n", omittingEmptySubsequences: false)[line - 1]
                    if !Self.isAllowedViolation(relative: relative, pattern: regex.pattern, line: String(lineText)) {
                        violations.append("\(relative):\(line): \(regex.pattern)")
                    }
                }
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    private static func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "GenericMonitoringPingLeakGrepGateTests", code: 1)
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.path.contains("/.build/") { continue }
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true && url.pathExtension == "swift" {
                result.append(url)
            }
        }
        return result
    }

    private static func isAllowlisted(_ url: URL, root: URL) -> Bool {
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        if relative.hasPrefix("Sources/AmbitCore/Ping/") { return true }
        return false
    }

    private static func isAllowedViolation(relative: String, pattern: String, line: String) -> Bool {
        guard relative == "Sources/AmbitMenuBar/StatusViewModel.swift",
              pattern == #"IntegrationIDs\.ping"#
        else { return false }
        let allowedSnippets = [
            "selection: .integrationType(IntegrationIDs.ping)",
            "record.integrationID != IntegrationIDs.ping",
            "$0.integrationID == IntegrationIDs.ping",
            "disabled.contains(IntegrationIDs.ping)",
            "disabled.subtracting([IntegrationIDs.ping])",
            "record.integrationID == IntegrationIDs.ping",
            "integrationID: IntegrationIDs.ping",
            "case IntegrationIDs.ping:"
        ]
        return allowedSnippets.contains { line.contains($0) }
    }
}
