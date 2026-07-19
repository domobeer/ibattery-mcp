// Tests/IBatteryCoreTests/BLEHelperStatusWarningTests.swift
import XCTest
@testable import IBatteryCore

final class BLEHelperStatusWarningTests: XCTestCase {
    func testBleHelperStatusWarning_nilStatus_returnsUnreachableMessage() {
        let warning = bleHelperStatusWarning(status: nil)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("isn't running") ?? false)
    }

    func testBleHelperStatusWarning_notAuthorized_returnsPermissionMessage() {
        let status = BLEHelperBluetoothStatus(authorized: false, poweredOn: false)
        let warning = bleHelperStatusWarning(status: status)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("permission") ?? false)
    }

    func testBleHelperStatusWarning_authorizedButNotPoweredOn_returnsPoweredOffMessage() {
        let status = BLEHelperBluetoothStatus(authorized: true, poweredOn: false)
        let warning = bleHelperStatusWarning(status: status)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("turned off") ?? false)
    }

    func testBleHelperStatusWarning_authorizedAndPoweredOn_returnsNil() {
        let status = BLEHelperBluetoothStatus(authorized: true, poweredOn: true)
        XCTAssertNil(bleHelperStatusWarning(status: status))
    }
}
