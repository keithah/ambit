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

            // Each pipe is read to end-of-file by one reader, and the result is delivered only after
            // both readers finish, so no output can arrive after the buffers are read.
            let readers = DispatchGroup()
            readers.enter()
            readers.enter()
            process.terminationHandler = { process in
                let status = process.terminationStatus
                readers.notify(queue: .global(qos: .utility)) {
                    state.resume(.success(ProcessResult(
                        exitCode: status, stdout: stdoutBuffer.string(), stderr: stderrBuffer.string()
                    )))
                }
            }
            do {
                try process.run()
            } catch {
                readers.leave()
                readers.leave()
                state.resume(.failure(error))
                return
            }
            for (pipe, buffer) in [(stdout, stdoutBuffer), (stderr, stderrBuffer)] {
                let handle = UncheckedSendableBox(pipe.fileHandleForReading)
                DispatchQueue.global(qos: .utility).async {
                    buffer.append(handle.value.readDataToEndOfFile())
                    readers.leave()
                }
            }

            let box = UncheckedSendableBox(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.resume(.failure(ProcessTimedOut())) else { return }
                guard box.value.isRunning else { return }
                box.value.terminate()
                // A child that ignores SIGTERM is killed rather than left running.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if box.value.isRunning { kill(box.value.processIdentifier, SIGKILL) }
                }
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
