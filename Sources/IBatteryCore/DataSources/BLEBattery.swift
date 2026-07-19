// Sources/IBatteryCore/DataSources/BLEBattery.swift
import CoreBluetooth
import Foundation

public let batteryServiceUUID = CBUUID(string: "180F")
public let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

public func parseBatteryLevelCharacteristic(_ data: Data) -> Int? {
    guard let firstByte = data.first else { return nil }
    return Int(firstByte)
}

public final class BLEBatteryScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [CBPeripheral] = []
    private var pendingPeripherals: Set<UUID> = []
    private var results: [DeviceBatteryInfo] = []
    private var continuation: CheckedContinuation<[DeviceBatteryInfo], Never>?
    private var scanDuration: TimeInterval = 4.0
    private var finished = false

    public override init() {
        super.init()
    }

    public func scan(duration: TimeInterval = 4.0) async -> [DeviceBatteryInfo] {
        scanDuration = duration
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.centralManager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        centralManager.stopScan()
        continuation?.resume(returning: results)
        continuation = nil
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            finish()
            return
        }
        central.scanForPeripherals(withServices: [batteryServiceUUID], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + scanDuration) { [weak self] in
            self?.finish()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !pendingPeripherals.contains(peripheral.identifier) else { return }
        pendingPeripherals.insert(peripheral.identifier)
        discoveredPeripherals.append(peripheral)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pendingPeripherals.remove(peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == batteryServiceUUID {
            peripheral.discoverCharacteristics([batteryLevelCharacteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == batteryLevelCharacteristicUUID {
            peripheral.readValue(for: characteristic)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == batteryLevelCharacteristicUUID,
              let data = characteristic.value,
              let percentage = parseBatteryLevelCharacteristic(data)
        else { return }

        let info = DeviceBatteryInfo(
            id: peripheral.identifier.uuidString,
            name: peripheral.name ?? "Unknown BLE Device",
            kind: .bleGeneric,
            percentage: percentage,
            isCharging: nil,
            lastUpdated: Date()
        )
        results.append(info)
        centralManager.cancelPeripheralConnection(peripheral)
    }
}

public struct BLEBatterySource: Sendable {
    let scanDuration: TimeInterval
    public init(scanDuration: TimeInterval = 4.0) {
        self.scanDuration = scanDuration
    }
    public func fetchAll() async -> [DeviceBatteryInfo] {
        await BLEBatteryScanner().scan(duration: scanDuration)
    }
}
