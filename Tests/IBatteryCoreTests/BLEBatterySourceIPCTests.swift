// Tests/IBatteryCoreTests/BLEBatterySourceIPCTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLEBatterySourceIPCTests: XCTestCase {
    func testParseHelperResponse_decodesValidJSONArray() {
        let json = """
        [{"id":"abc","name":"Test Mouse","kind":"bleGeneric","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z","stale":false}]
        """
        let data = Data(json.utf8)
        let devices = parseHelperResponse(data)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "abc")
        XCTAssertEqual(devices.first?.percentage, 72)
    }

    func testParseHelperResponse_emptyArray_returnsEmpty() {
        let data = Data("[]".utf8)
        XCTAssertEqual(parseHelperResponse(data), [])
    }

    func testParseHelperResponse_malformedData_returnsEmpty() {
        let data = Data("not json".utf8)
        XCTAssertEqual(parseHelperResponse(data), [])
    }

    func testDecodeBLEHelperBluetoothStatus_authorizedAndPoweredOn() {
        let json = #"{"authorized":true,"poweredOn":true}"#
        let data = Data(json.utf8)
        let status = try? deviceJSONDecoder.decode(BLEHelperBluetoothStatus.self, from: data)
        XCTAssertEqual(status, BLEHelperBluetoothStatus(authorized: true, poweredOn: true))
    }

    func testDecodeBLEHelperBluetoothStatus_notAuthorizedNotPoweredOn() {
        let json = #"{"authorized":false,"poweredOn":false}"#
        let data = Data(json.utf8)
        let status = try? deviceJSONDecoder.decode(BLEHelperBluetoothStatus.self, from: data)
        XCTAssertEqual(status, BLEHelperBluetoothStatus(authorized: false, poweredOn: false))
    }

    func testDecodeBLEHelperBluetoothStatus_malformedData_returnsNil() {
        let data = Data("not json".utf8)
        let status = try? deviceJSONDecoder.decode(BLEHelperBluetoothStatus.self, from: data)
        XCTAssertNil(status)
    }
}
