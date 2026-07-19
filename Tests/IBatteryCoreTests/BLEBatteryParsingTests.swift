// Tests/IBatteryCoreTests/BLEBatteryParsingTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLEBatteryParsingTests: XCTestCase {
    func testParseBatteryLevelCharacteristic_returnsPercentage() {
        let data = Data([100])
        XCTAssertEqual(parseBatteryLevelCharacteristic(data), 100)
    }

    func testParseBatteryLevelCharacteristic_emptyData_returnsNil() {
        XCTAssertNil(parseBatteryLevelCharacteristic(Data()))
    }
}
