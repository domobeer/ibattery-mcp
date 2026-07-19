import XCTest
@testable import IBatteryCore

private struct FakeBatterySource: BatteryDataSource {
    let devices: [DeviceBatteryInfo]
    func fetchAll() async -> [DeviceBatteryInfo] { devices }
}

final class DeviceRegistryTests: XCTestCase {
    func testGetAllDevicesStatus_aggregatesAllSources() async {
        let source1 = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "a", name: "Mac", kind: .mac, percentage: 90, isCharging: true, lastUpdated: Date())
        ])
        let source2 = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "b", name: "Generic BLE", kind: .bleGeneric, percentage: 60, isCharging: nil, lastUpdated: Date())
        ])
        let registry = DeviceRegistry(sources: [source1, source2])
        let result = await registry.getAllDevicesStatus()
        XCTAssertEqual(result.count, 2)
    }

    func testGetDeviceBattery_findsMatchingDeviceByNameSubstring() async {
        let source = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "a", name: "MacBook Pro", kind: .mac, percentage: 90, isCharging: true, lastUpdated: Date())
        ])
        let registry = DeviceRegistry(sources: [source])
        let result = await registry.getDeviceBattery(query: "macbook")
        XCTAssertEqual(result?.id, "a")
    }

    func testGetDeviceBattery_noMatch_returnsNil() async {
        let registry = DeviceRegistry(sources: [])
        let result = await registry.getDeviceBattery(query: "nonexistent")
        XCTAssertNil(result)
    }

    func testListKnownDevices_returnsCachedAfterScan() async {
        let source = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "a", name: "Mac", kind: .mac, percentage: 90, isCharging: true, lastUpdated: Date())
        ])
        let registry = DeviceRegistry(sources: [source])
        _ = await registry.getAllDevicesStatus()
        let known = await registry.listKnownDevices()
        XCTAssertEqual(known.count, 1)
    }

    func testListKnownDevices_emptyBeforeAnyScan() async {
        let registry = DeviceRegistry(sources: [])
        let known = await registry.listKnownDevices()
        XCTAssertEqual(known.count, 0)
    }
}
