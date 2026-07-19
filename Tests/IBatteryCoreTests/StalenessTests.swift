// Tests/IBatteryCoreTests/StalenessTests.swift
import XCTest
@testable import IBatteryCore

private struct FakeBatterySource: BatteryDataSource {
    let devices: [DeviceBatteryInfo]
    func fetchAll() async -> [DeviceBatteryInfo] { devices }
}

final class StalenessTests: XCTestCase {
    func testMarkStaleIfNeeded_marksOldDeviceAsStale() {
        let oldDevice = DeviceBatteryInfo(
            id: "a", name: "Old Device", kind: .bleGeneric,
            percentage: 50, isCharging: nil,
            lastUpdated: Date().addingTimeInterval(-200)
        )
        let result = markStaleIfNeeded(oldDevice, now: Date(), threshold: 120)
        XCTAssertTrue(result.stale)
    }

    func testMarkStaleIfNeeded_leavesFreshDeviceAlone() {
        let freshDevice = DeviceBatteryInfo(
            id: "a", name: "Fresh Device", kind: .mac,
            percentage: 90, isCharging: true,
            lastUpdated: Date()
        )
        let result = markStaleIfNeeded(freshDevice, now: Date(), threshold: 120)
        XCTAssertFalse(result.stale)
    }

    func testListKnownDevices_marksOldCachedEntriesAsStale() async {
        let source = FakeBatterySource(devices: [
            DeviceBatteryInfo(
                id: "a", name: "Mac", kind: .mac, percentage: 90,
                isCharging: true, lastUpdated: Date().addingTimeInterval(-200)
            )
        ])
        let registry = DeviceRegistry(sources: [source])
        _ = await registry.getAllDevicesStatus()
        let known = await registry.listKnownDevices()
        XCTAssertEqual(known.first?.stale, true)
    }

    func testBleHelperUnreachableWarning_falseReturnsMessage() {
        XCTAssertNotNil(bleHelperUnreachableWarning(canConnect: false))
    }

    func testBleHelperUnreachableWarning_trueReturnsNil() {
        XCTAssertNil(bleHelperUnreachableWarning(canConnect: true))
    }
}
