import Foundation
import Darwin

/// File-backed capture avoids stdout/stderr pipe backpressure and preserves large JSON.
enum SubprocessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    enum RunError: LocalizedError {
        case timedOut
        var errorDescription: String? { "解析进程超时，已停止本次尝试。" }
    }

    /// Cancellation only wakes the owning worker; that worker stops its own child.
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var wakeup: DispatchSemaphore?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func bind(_ semaphore: DispatchSemaphore) {
            lock.lock()
            wakeup = semaphore
            let shouldWake = cancelled
            lock.unlock()
            if shouldWake { semaphore.signal() }
        }

        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true
            let semaphore = wakeup
            lock.unlock()
            semaphore?.signal()
        }
    }

    static func runAsync(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> Output {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output = try await Task.detached(priority: .utility) {
                try run(executable: executable, arguments: arguments, environment: environment,
                        timeout: timeout, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            return output
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Run from a background worker. Only this invocation's child is stopped on timeout.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> Output {
        try run(executable: executable, arguments: arguments, environment: environment,
                timeout: timeout, cancellation: nil)
    }

    private static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        cancellation: CancellationState?
    ) throws -> Output {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HERMES-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        try Data().write(to: outURL)
        try Data().write(to: errURL)
        let outHandle = try FileHandle(forWritingTo: outURL)
        defer { try? outHandle.close() }
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        let finished = DispatchSemaphore(value: 0)
        cancellation?.bind(finished)
        process.terminationHandler = { _ in finished.signal() }
        if cancellation?.isCancelled == true { throw CancellationError() }
        try process.run()
        let result = finished.wait(timeout: .now() + max(timeout, 0.01))
        if cancellation?.isCancelled == true {
            stop(process, finished: finished)
            throw CancellationError()
        }
        if result == .timedOut {
            stop(process, finished: finished)
            throw RunError.timedOut
        }
        return Output(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: outURL),
            stderr: try Data(contentsOf: errURL)
        )
    }

    private static func stop(_ process: Process, finished: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}
