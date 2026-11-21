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

public struct ProcessTimedOut: Error, Sendable {}

public protocol ProcessRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

/// Runs a child process with an argument vector (never a shell) and a hard timeout.
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = RunState(continuation: continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = OutputBuffer()
            let stderrBuffer = OutputBuffer()
            process.standardOutput = stdout
            process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdoutBuffer.append(data) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrBuffer.append(data) }
            }
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.availableData)
                stderrBuffer.append(stderr.fileHandleForReading.availableData)
                state.resume(.success(ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdoutBuffer.string(),
                    stderr: stderrBuffer.string()
                )))
            }
            do {
                try process.run()
            } catch {
                state.resume(.failure(error))
                return
            }
            let box = UncheckedSendableBox(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.resume(.failure(ProcessTimedOut())) else { return }
                if box.value.isRunning { box.value.terminate() }
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
    }

    func string() -> String {
        String(data: lock.withLock { data }, encoding: .utf8) ?? ""
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<ProcessResult, Error>

    init(continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<ProcessResult, Error>) -> Bool {
        lock.withLock {
            guard !didResume else { return false }
            didResume = true
            continuation.resume(with: result)
            return true
        }
    }
}

/// Single-use guard: a continuation must resume exactly once even when several callbacks race.
final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Carries a non-Sendable reference (Process, NWConnection) into a @Sendable closure.
final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
