// Tests/IBatteryCoreTests/BLEAdvertisementCacheTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLEAdvertisementCacheTests: XCTestCase {
    private let podsID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let phoneID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func openMessage(left: UInt8 = 0x40, right: UInt8 = 0x3C, caseByte: UInt8 = 0xC8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0x4C; bytes[1] = 0x00; bytes[2] = 0x07
        bytes[7] = 0x20 | 0x05 // flip bit set (no swap), both buds in case
        bytes[14] = left; bytes[15] = right; bytes[16] = caseByte
        return Data(bytes)
    }

    private func closeMessage() -> Data {
        var bytes = [UInt8](repeating: 0, count: 25)
        bytes[0] = 0x4C; bytes[1] = 0x00; bytes[2] = 0x12
        bytes[4] = 0x2C // only left taken out
        bytes[12] = 0x40; bytes[13] = 0x32; bytes[14] = 0x3C
        return Data(bytes)
    }

    func testIngestOpenMessage_producesThreeEntriesWithSuffixesAndFields() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: openMessage(), at: now)

        let entries = cache.airpodsEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.name).sorted(), ["Test Pods (Case)", "Test Pods (Left)", "Test Pods (Right)"])

        let left = entries.first { $0.name == "Test Pods (Left)" }
        XCTAssertEqual(left?.id, "ble-\(podsID.uuidString.lowercased())-left")
        XCTAssertEqual(left?.kind, .airpods)
        XCTAssertEqual(left?.percentage, 64)
        XCTAssertEqual(left?.isCharging, false)
        XCTAssertEqual(left?.inCase, true)
        XCTAssertNil(left?.lidOpen)
        XCTAssertEqual(left?.lastUpdated, now)

        let caseEntry = entries.first { $0.name == "Test Pods (Case)" }
        XCTAssertEqual(caseEntry?.percentage, 72)
        XCTAssertEqual(caseEntry?.isCharging, true)
        XCTAssertEqual(caseEntry?.lidOpen, true)
        XCTAssertNil(caseEntry?.inCase)
    }

    func testIngestCloseMessage_overwritesPreviousState() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: openMessage(), at: now)
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: closeMessage(), at: now.addingTimeInterval(60))

        let entries = cache.airpodsEntries()
        let left = entries.first { $0.name == "Test Pods (Left)" }
        XCTAssertEqual(left?.inCase, false) // close message: only left taken out
        XCTAssertEqual(left?.lastUpdated, now.addingTimeInterval(60))
        let caseEntry = entries.first { $0.name == "Test Pods (Case)" }
        XCTAssertEqual(caseEntry?.lidOpen, false)
    }

    func testIngestFFComponent_omitsThatEntry() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: openMessage(left: 0xFF), at: now)
        let names = cache.airpodsEntries().map(\.name)
        XCTAssertFalse(names.contains("Test Pods (Left)"))
        XCTAssertTrue(names.contains("Test Pods (Right)"))
    }

    func testIngestIOSCandidate_recordsPeripheralID() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test iPhone", peripheralID: phoneID, manufacturerData: Data([0x4C, 0x00, 0x10, 0x00]), at: now)
        XCTAssertEqual(cache.iosCandidates["Test iPhone"], phoneID)
        XCTAssertTrue(cache.airpodsEntries().isEmpty)
    }

    func testIngestUnrecognizedData_isIgnored() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Mystery", peripheralID: phoneID, manufacturerData: Data([0x99, 0x00, 0x07]), at: now)
        XCTAssertTrue(cache.airpodsEntries().isEmpty)
        XCTAssertTrue(cache.iosCandidates.isEmpty)
    }
}
