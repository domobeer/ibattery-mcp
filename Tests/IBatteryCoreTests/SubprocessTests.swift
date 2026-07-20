// Tests/IBatteryCoreTests/SubprocessTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class SubprocessTests: XCTestCase {
    func testRunSubprocess_hangingProcess_returnsPromptlyOnTimeout() {
        let start = Date()
        let result = runSubprocess("sleep", ["10"], timeoutSeconds: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(elapsed, 5.0, "watchdog should terminate the hung process well before the full 10s sleep completes")
    }

    func testRunSubprocess_fastProcess_succeedsWithinTimeout() {
        let result = runSubprocess("true", [], timeoutSeconds: 5.0)
        XCTAssertEqual(result.exitCode, 0)
    }
}
