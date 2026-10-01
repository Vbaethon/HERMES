import Foundation
import Darwin
import XCTest
@testable import HermesNetworking

final class SubprocessRunnerTests: XCTestCase {
    func testCapturesLargeStdoutAndStderrWithoutDeadlock() throws {
        let result = try SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "for (1..128) { print STDOUT 'a' x 8192; print STDERR 'b' x 8192; }"],
            timeout: 5
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data(repeating: 97, count: 1_048_576))
        XCTAssertEqual(result.stderr, Data(repeating: 98, count: 1_048_576))
    }

    func testNonzeroExitRetainsDiagnostics() throws {
        let result = try SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf result; printf failure >&2; exit 7"], timeout: 3
        )
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "result")
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "failure")
    }

    func testTimeoutStopsUnresponsiveChild() throws {
        let start = Date()
        XCTAssertThrowsError(try SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30"], timeout: 0.2
        )) { error in
            XCTAssertTrue(error is SubprocessRunner.RunError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testLaunchFailureReturnsWithoutWaitingForTimeout() {
        XCTAssertThrowsError(try SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/no-such-hermes-test-executable"), arguments: [], timeout: 30
        ))
    }

    func testCancellationStopsOnlyItsOwnUnresponsiveChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("HERMES-cancel-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        unrelated.arguments = ["-e", "sleep 30"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }

        let task = Task {
            try await SubprocessRunner.runAsync(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", "$SIG{TERM} = 'IGNORE'; open my $f, '>', $ARGV[0] or die $!; print $f $$; close $f; sleep 30", marker.path],
                timeout: 30
            )
        }
        // Confirm the child actually launched before testing its cancellation.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let pidText = try? String(contentsOf: marker, encoding: .utf8),
              let pid = Int32(pidText) else {
            task.cancel()
            _ = try? await task.value
            XCTFail("The child did not start")
            return
        }
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled execution must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3)
        XCTAssertEqual(kill(pid, 0), -1, "The cancelled child must have exited")
        XCTAssertTrue(unrelated.isRunning, "Cancellation must leave unrelated processes running")
    }
}
