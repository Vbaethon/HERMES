import Foundation
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
}
