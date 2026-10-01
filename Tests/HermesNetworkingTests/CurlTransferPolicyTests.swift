import Foundation
import Darwin
import XCTest
@testable import HermesNetworking

private final class CurlTransferFixture: @unchecked Sendable {
    let root: URL
    private let process = Process()
    private let terminated = DispatchSemaphore(value: 0)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HERMES-curl-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
import http.server, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        with (root / 'requests').open('a') as log: log.write(self.path + '\n')
        self.send_response(200)
        self.send_header('Content-Length', '65536' if self.path == '/slow' else '1000000')
        self.end_headers()
        try:
            if self.path == '/slow':
                for _ in range(4):
                    self.wfile.write(b'x' * 16384)
                    self.wfile.flush()
                    time.sleep(0.3)
            elif self.path == '/trickle':
                for _ in range(100):
                    self.wfile.write(b'x' * 1024)
                    self.wfile.flush()
                    time.sleep(0.1)
            else:
                self.wfile.write(b'x' * 16384)
                self.wfile.flush()
                time.sleep(30)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
"""#
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", script, root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let terminated = self.terminated
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
    }

    func baseURL() async throws -> URL {
        let portFile = root.appendingPathComponent("port")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: portFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func requestCount(_ path: String) throws -> Int {
        try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").filter { $0 == path }.count
    }

    func stop() {
        if process.isRunning { process.terminate() }
        // XCTest async continuations can move between worker threads. Foundation's
        // waitUntilExit can then keep waiting even after the child has exited.
        if terminated.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 1)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

final class CurlTransferPolicyTests: XCTestCase {
    func testStalledTransferStopsWithoutHiddenRetryAndCleansPartialFile() async throws {
        let fixture = try CurlTransferFixture()
        defer { fixture.stop() }
        let base = try await fixture.baseURL()
        let destination = fixture.root.appendingPathComponent("stalled.part")
        let started = Date()
        do {
            try await DownloaderHTTPCompatibility.downloadAsync(URLRequest(url: base.appendingPathComponent("stall")),
                to: destination, transferPolicy: .init(maximumDuration: 20, idleTimeout: 1))
            XCTFail("A connected transfer that stops sending data must fail")
        } catch {
            XCTAssertEqual((error as NSError).code, 28, "curl must report its transfer timeout")
        }
        // curl evaluates low-speed periods over its moving transfer window.
        XCTAssertLessThan(Date().timeIntervalSince(started), 12, "The low-speed limit must fire before the resource deadline")
        XCTAssertEqual(try fixture.requestCount("/stall"), 1, "The source retry loop owns retries")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testHealthySlowTransferKeepsItsBytes() async throws {
        let fixture = try CurlTransferFixture()
        defer { fixture.stop() }
        let base = try await fixture.baseURL()
        let destination = fixture.root.appendingPathComponent("slow.bin")
        try await DownloaderHTTPCompatibility.downloadAsync(URLRequest(url: base.appendingPathComponent("slow")),
            to: destination, transferPolicy: .init(maximumDuration: 8, idleTimeout: 1))
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 120, count: 65_536))
        XCTAssertEqual(try fixture.requestCount("/slow"), 1)
    }

    func testResourceDeadlineBoundsTransferThatKeepsSendingBytes() async throws {
        let fixture = try CurlTransferFixture()
        defer { fixture.stop() }
        let base = try await fixture.baseURL()
        let destination = fixture.root.appendingPathComponent("trickle.part")
        let started = Date()
        do {
            try await DownloaderHTTPCompatibility.downloadAsync(URLRequest(url: base.appendingPathComponent("trickle")),
                to: destination, transferPolicy: .init(maximumDuration: 1.5, idleTimeout: 12))
            XCTFail("An active transfer must still have a resource deadline")
        } catch {
            XCTAssertEqual((error as NSError).code, 28)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertEqual(try fixture.requestCount("/trickle"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testBoundedTransferStillCancelsPromptly() async throws {
        let fixture = try CurlTransferFixture()
        defer { fixture.stop() }
        let base = try await fixture.baseURL()
        let destination = fixture.root.appendingPathComponent("cancel.part")
        let task = Task {
            try await DownloaderHTTPCompatibility.downloadAsync(URLRequest(url: base.appendingPathComponent("cancel")),
                to: destination, transferPolicy: .init(maximumDuration: 90, idleTimeout: 12))
        }
        for _ in 0..<300 {
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = Date()
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled bounded transfer must throw")
        } catch {
            XCTAssertTrue(DownloaderHTTPCompatibility.isCancellation(error))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(try fixture.requestCount("/cancel"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
