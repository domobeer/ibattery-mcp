// Sources/IBatteryCore/DataSources/BLEBattery.swift
import CoreBluetooth
import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

    private func cleanup(_ peripheral: CBPeripheral) {
        pendingPeripherals.remove(peripheral.identifier)
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        centralManager.stopScan()
        // Clean up any peripherals still in-flight when timeout fires
        for peripheral in discoveredPeripherals {
            if peripheral.state == .connected || peripheral.state == .connecting {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
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
        guard error == nil, let services = peripheral.services else {
            cleanup(peripheral)
            return
        }
        var found = false
        for service in services where service.uuid == batteryServiceUUID {
            peripheral.discoverCharacteristics([batteryLevelCharacteristicUUID], for: service)
            found = true
        }
        if !found {
            cleanup(peripheral)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            cleanup(peripheral)
            return
        }
        var found = false
        for characteristic in characteristics where characteristic.uuid == batteryLevelCharacteristicUUID {
            peripheral.readValue(for: characteristic)
            found = true
        }
        if !found {
            cleanup(peripheral)
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
        else {
            cleanup(peripheral)
            return
        }

        let info = DeviceBatteryInfo(
            id: peripheral.identifier.uuidString,
            name: peripheral.name ?? "Unknown BLE Device",
            kind: .bleGeneric,
            percentage: percentage,
            isCharging: nil,
            lastUpdated: Date()
        )
        results.append(info)
        cleanup(peripheral)
    }
}

public func parseHelperResponse(_ data: Data) -> [DeviceBatteryInfo] {
    (try? deviceJSONDecoder.decode([DeviceBatteryInfo].self, from: data)) ?? []
}

public func bleHelperUnreachableWarning(canConnect: Bool) -> String? {
    guard !canConnect else { return nil }
    return "ibattery-ble-helper isn't running, so nearby Bluetooth devices (other than this Mac's own battery) weren't checked. Launch it once (double-click the .app, or `open` it) — it stays running in the background afterward."
}

public struct BLEBatterySource: BatteryDataSource {
    let readTimeoutSeconds: Int

    public init(readTimeoutSeconds: Int = 6) {
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.fetchAllBlocking())
            }
        }
    }

    public static func canReachHelper() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var addr = makeUnixSocketAddress(path: bleHelperSocketPath) else { return false }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func fetchAllBlocking() -> [DeviceBatteryInfo] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var readTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Without this, a write() to a socket whose peer has already closed
        // the connection (e.g. the helper app quit mid-request) raises
        // SIGPIPE, whose default disposition terminates the process — which
        // would crash the MCP process itself, exactly what this whole
        // component exists to avoid. SO_NOSIGPIPE makes write() return
        // EPIPE as an ordinary error instead.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // makeUnixSocketAddress returns an Optional (nil only if the path is
        // too long for sockaddr_un.sun_path); it must be unwrapped before we
        // take its address, otherwise we'd be taking the address of the
        // Optional wrapper rather than the sockaddr_un payload itself, which
        // has no guaranteed memory layout compatible with `sockaddr`. This
        // mirrors the proven pattern already used server-side in
        // Sources/ibattery-ble-helper/main.swift.
        guard var addr = makeUnixSocketAddress(path: bleHelperSocketPath) else { return [] }
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            // Helper not installed/running — not an error, just no BLE data this call.
            return []
        }

        let request = "scan\n"
        request.withCString { cString in
            _ = write(fd, cString, strlen(cString))
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            guard bytesRead > 0 else { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }

        return parseHelperResponse(responseData)
    }
}
