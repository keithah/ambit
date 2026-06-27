import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval = 5) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = ProcessRunState(continuation: continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            process.standardOutput = stdout
            process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stdoutBuffer.append(data)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let remainingStdout = stdout.fileHandleForReading.availableData
                let remainingStderr = stderr.fileHandleForReading.availableData
                if !remainingStdout.isEmpty {
                    stdoutBuffer.append(remainingStdout)
                }
                if !remainingStderr.isEmpty {
                    stderrBuffer.append(remainingStderr)
                }
                let result = ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdoutBuffer.string(),
                    stderr: stderrBuffer.string()
                )
                state.resume(.success(result))
            }

            do {
                try process.run()
            } catch {
                state.resume(.failure(error))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.resume(.failure(JSONRPCClientError.commandFailed("Process timed out."))) else { return }
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

public struct PSProcessRow: Equatable, Sendable {
    public var pid: Int
    public var name: String
    public var cpuPercent: Double
    public var memoryBytes: Double

    public init(pid: Int, name: String, cpuPercent: Double, memoryBytes: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    public var rowID: String { "\(pid):\(name)" }
}

public enum PSProcessParser {
    public static func parse(_ output: String) -> [PSProcessRow] {
        output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap(parseLine)
    }

    private static func parseLine(_ line: Substring) -> PSProcessRow? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4,
              let pid = Int(parts[0]),
              let cpuPercent = Double(parts[1]),
              let residentKilobytes = Double(parts[2])
        else { return nil }

        return PSProcessRow(
            pid: pid,
            name: displayName(from: String(parts[3])),
            cpuPercent: cpuPercent,
            memoryBytes: residentKilobytes * 1024
        )
    }

    private static func displayName(from command: String) -> String {
        let name = URL(fileURLWithPath: command).lastPathComponent
        return name.isEmpty ? command : name
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<ProcessResult, Error>

    init(continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<ProcessResult, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        continuation.resume(with: result)
        return true
    }
}
