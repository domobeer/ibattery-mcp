// Tests/IBatteryCoreTests/AirPodsAdvertisementTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class AirPodsAdvertisementTests: XCTestCase {
    // Synthesized fixtures per the byte layout in
    // docs/superpowers/specs/2026-07-20-ble-advertisement-design.md §3.
    // Battery byte encoding: 0xff = absent; else bit 7 = charging,
    // low 7 bits = percentage.

    /// flipBitSet=true → byte 7 high nibble carries 0x02 → NOT flipped
    /// (left at 14, right at 15). flipBitSet=false → flipped (swapped).
    private func makeOpenMessage(
        coarseNibble: UInt8,
        flipBitSet: Bool = true,
        byte14: UInt8,
        byte15: UInt8,
        caseByte: UInt8
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x07
        bytes[7] = (flipBitSet ? 0x20 : 0x00) | (coarseNibble & 0x0F)
        bytes[14] = byte14
        bytes[15] = byte15
        bytes[16] = caseByte
        return Data(bytes)
    }

    private func makeCloseMessage(
        stateByte: UInt8,
        caseByte: UInt8,
        leftByte: UInt8,
        rightByte: UInt8
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 25)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x12
        bytes[4] = stateByte
        bytes[12] = caseByte
        bytes[13] = leftByte
        bytes[14] = rightByte
        return Data(bytes)
    }

    // MARK: classification

    func testClassify_openMessage() {
        XCTAssertEqual(classifyAppleManufacturerData(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x40, caseByte: 0x40)), .airpodsOpen)
    }

    func testClassify_closeMessage() {
        XCTAssertEqual(classifyAppleManufacturerData(makeCloseMessage(stateByte: 0x2E, caseByte: 0x40, leftByte: 0x40, rightByte: 0x40)), .airpodsClose)
    }

    func testClassify_iosCandidateTypes() {
        for typeByte: UInt8 in [0x10, 0x0C] {
            let data = Data([0x4C, 0x00, typeByte, 0x00, 0x00])
            XCTAssertEqual(classifyAppleManufacturerData(data), .iosCandidate)
        }
    }

    func testClassify_nonAppleCompanyID_returnsNil() {
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4D, 0x00, 0x07])))
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x01, 0x07])))
    }

    func testClassify_tooShort_returnsNil() {
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x00])))
        XCTAssertNil(classifyAppleManufacturerData(Data()))
    }

    func testClassify_airpodsTypeWithWrongLength_returnsNil() {
        // type 0x07 but not 29 bytes; type 0x12 but not 25 bytes
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x00, 0x07, 0x00])))
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x00, 0x12, 0x00])))
    }

    // MARK: battery byte decoding (via the parsers)

    func testOpen_batteryBytes_levelAndCharging() {
        // 0x40 = 64%, not charging; 0x85 = 5%, charging
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x85, caseByte: 0xE4))
        XCTAssertEqual(state?.left.percentage, 64)
        XCTAssertEqual(state?.left.isCharging, false)
        XCTAssertEqual(state?.right.percentage, 5)
        XCTAssertEqual(state?.right.isCharging, true)
        XCTAssertEqual(state?.caseComponent.percentage, 100) // 0xE4 & 0x7F
        XCTAssertEqual(state?.caseComponent.isCharging, true)
    }

    func testOpen_ffByte_componentAbsent() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 1, byte14: 0xFF, byte15: 0x40, caseByte: 0xFF))
        XCTAssertNil(state?.left.percentage)
        XCTAssertNil(state?.left.isCharging)
        XCTAssertEqual(state?.right.percentage, 64)
        XCTAssertNil(state?.caseComponent.percentage)
    }

    func testOpen_invalidLevelOver100NotCharging_componentAbsent() {
        // 0x7F = 127 with charging bit clear — impossible level, treat as absent
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x7F, byte15: 0x40, caseByte: 0x40))
        XCTAssertNil(state?.left.percentage)
    }

    // MARK: open-message in-case confidence rules

    func testOpen_nibble5_bothBudsInCase() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x40, caseByte: 0x40))
        XCTAssertEqual(state?.left.inCase, true)
        XCTAssertEqual(state?.right.inCase, true)
        XCTAssertNil(state?.caseComponent.inCase)
        XCTAssertEqual(state?.lidOpen, true)
    }

    func testOpen_nibble1_chargingBudIsInCase_otherUnknown() {
        // left charging → certainly in case; right not charging → unknown
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 1, byte14: 0x85, byte15: 0x40, caseByte: 0x40))
        XCTAssertEqual(state?.left.inCase, true)
        XCTAssertNil(state?.right.inCase)
    }

    func testOpen_unknownNibble_inCaseUnknown() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 3, byte14: 0x40, byte15: 0x40, caseByte: 0x40))
        XCTAssertNil(state?.left.inCase)
        XCTAssertNil(state?.right.inCase)
    }

    func testOpen_flipBitClear_swapsLeftAndRightBytes() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, flipBitSet: false, byte14: 0x0A, byte15: 0x14, caseByte: 0x40))
        // flipped: left comes from byte 15 (0x14 = 20%), right from byte 14 (0x0A = 10%)
        XCTAssertEqual(state?.left.percentage, 20)
        XCTAssertEqual(state?.right.percentage, 10)
    }

    // MARK: close-message parsing

    func testClose_stateByteVariants() {
        struct TestCase {
            let stateByte: UInt8
            let expectedLeft: Bool?
            let expectedRight: Bool?
        }

        let cases = [
            TestCase(stateByte: 0x2E, expectedLeft: true, expectedRight: true),   // both in case
            TestCase(stateByte: 0x2C, expectedLeft: false, expectedRight: true),  // only left taken out
            TestCase(stateByte: 0x26, expectedLeft: true, expectedRight: false),  // only right taken out
            TestCase(stateByte: 0x24, expectedLeft: false, expectedRight: false), // both out
            TestCase(stateByte: 0x99, expectedLeft: nil, expectedRight: nil)      // unknown value → never guess
        ]
        for testCase in cases {
            let state = parseAirPodsCloseMessage(makeCloseMessage(stateByte: testCase.stateByte, caseByte: 0x40, leftByte: 0x40, rightByte: 0x40))
            XCTAssertEqual(state?.left.inCase, testCase.expectedLeft, "state byte \(testCase.stateByte)")
            XCTAssertEqual(state?.right.inCase, testCase.expectedRight, "state byte \(testCase.stateByte)")
        }
    }

    func testClose_batteryByteMapping_andLidClosed() {
        let state = parseAirPodsCloseMessage(makeCloseMessage(stateByte: 0x2E, caseByte: 0xC8, leftByte: 0x32, rightByte: 0x3C))
        XCTAssertEqual(state?.caseComponent.percentage, 72) // 0xC8 & 0x7F
        XCTAssertEqual(state?.caseComponent.isCharging, true)
        XCTAssertEqual(state?.left.percentage, 50)
        XCTAssertEqual(state?.right.percentage, 60)
        XCTAssertEqual(state?.lidOpen, false)
    }

    func testParsers_rejectWrongShape() {
        XCTAssertNil(parseAirPodsOpenMessage(makeCloseMessage(stateByte: 0x2E, caseByte: 0x40, leftByte: 0x40, rightByte: 0x40)))
        XCTAssertNil(parseAirPodsCloseMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x40, caseByte: 0x40)))
        XCTAssertNil(parseAirPodsOpenMessage(Data()))
    }
}
