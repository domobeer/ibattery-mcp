// Tests/IBatteryCoreTests/HelpFlagTests.swift
import XCTest

final class HelpFlagTests: XCTestCase {
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Couldn't find the products directory")
    }

    private var executableURL: URL {
        productsDirectory.appendingPathComponent("ibattery-mcp")
    }

    func testHelpFlagPrintsUsageAndExitsCleanly() throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--help"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()

        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("ibattery-mcp"), "Expected usage text to mention ibattery-mcp, got: \(output)")
        XCTAssertEqual(process.terminationStatus, 0, "Expected --help to exit 0, got: \(process.terminationStatus)")
    }

    func testShortHelpFlagAlsoPrintsUsage() throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-h"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()

        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("ibattery-mcp"), "Expected usage text to mention ibattery-mcp, got: \(output)")
        XCTAssertEqual(process.terminationStatus, 0, "Expected -h to exit 0, got: \(process.terminationStatus)")
    }
}
