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

    /// Run from a background worker. Only this invocation's child is stopped on timeout.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> Output {
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
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + max(timeout, 0.01)) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw RunError.timedOut
        }
        return Output(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: outURL),
            stderr: try Data(contentsOf: errURL)
        )
    }
}
