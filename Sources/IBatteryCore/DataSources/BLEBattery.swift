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

/// Wire shape for the helper's `"status"` request — a quick Bluetooth-state
/// check that doesn't require running a full ~4s scan. JSON shape:
/// `{"authorized":true,"poweredOn":true}`. Produced server-side by
/// `BLEBluetoothStatusChecker` (inside ibattery-ble-helper) and consumed
/// client-side by `BLEBatterySource.fetchBluetoothStatus()`.
public struct BLEHelperBluetoothStatus: Codable, Sendable, Equatable {
    public let authorized: Bool
    public let poweredOn: Bool

    public init(authorized: Bool, poweredOn: Bool) {
        self.authorized = authorized
        self.poweredOn = poweredOn
    }
}

/// Runs only inside ibattery-ble-helper. Creates a `CBCentralManager` and
/// resolves as soon as the *first* `centralManagerDidUpdateState` callback
/// fires — no scanning involved, so this is fast (typically sub-second)
/// compared to a full `BLEBatteryScanner` scan, which is the point: it lets
/// the client distinguish "Bluetooth off"/"permission denied" from "nothing
/// nearby" without paying the full scan's ~4s cost.
public final class BLEBluetoothStatusChecker: NSObject, CBCentralManagerDelegate {
    private var centralManager: CBCentralManager!
    private var continuation: CheckedContinuation<BLEHelperBluetoothStatus, Never>?

    public override init() {
        super.init()
    }

    public func checkStatus() async -> BLEHelperBluetoothStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.centralManager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let status = BLEHelperBluetoothStatus(
            authorized: CBManager.authorization == .allowedAlways,
            poweredOn: central.state == .poweredOn
        )
        continuation?.resume(returning: status)
        continuation = nil
    }
}

/// Produces the user-facing warning for the current Bluetooth-helper state,
/// or `nil` if everything's fine and no warning is needed.
/// - `status == nil` means the helper couldn't be reached at all (not running).
/// - `authorized == false` means the helper is running but lacks Bluetooth
///   permission (TCC-denied or restricted).
/// - `poweredOn == false` means the helper is running and authorized, but
///   Bluetooth itself is turned off.
public func bleHelperStatusWarning(status: BLEHelperBluetoothStatus?) -> String? {
    guard let status else {
        return "ibattery-ble-helper isn't running, so nearby Bluetooth devices (other than this Mac's own battery) weren't checked. Launch it once (double-click the .app, or `open` it) — it stays running in the background afterward."
    }
    guard status.authorized else {
        return "ibattery-ble-helper is running but doesn't have Bluetooth permission, so nearby Bluetooth devices weren't checked. Grant access in System Settings > Privacy & Security > Bluetooth, then try again."
    }
    guard status.poweredOn else {
        return "ibattery-ble-helper is running and authorized, but Bluetooth is turned off, so nearby Bluetooth devices weren't checked. Turn Bluetooth on and try again."
    }
    return nil
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
        guard let fd = Self.connectToHelper(readTimeoutSeconds: readTimeoutSeconds) else {
            // Helper not installed/running — not an error, just no BLE data this call.
            return []
        }
        defer { close(fd) }
        let responseData = Self.sendRequestAndReadResponse(fd: fd, request: "scan\n")
        return parseHelperResponse(responseData)
    }

    /// Asks the helper for its current Bluetooth state (authorization +
    /// powered-on) via the lightweight `"status"` request, without running a
    /// full scan. Returns `nil` if the helper can't be reached at all (not
    /// running) or if its response couldn't be decoded.
    public static func fetchBluetoothStatus(readTimeoutSeconds: Int = 6) -> BLEHelperBluetoothStatus? {
        guard let fd = connectToHelper(readTimeoutSeconds: readTimeoutSeconds) else { return nil }
        defer { close(fd) }
        let responseData = sendRequestAndReadResponse(fd: fd, request: "status\n")
        return try? deviceJSONDecoder.decode(BLEHelperBluetoothStatus.self, from: responseData)
    }

    /// Opens a connected, ready-to-use socket to the helper, or `nil` if it
    /// isn't reachable. Shared by `fetchAllBlocking()` and
    /// `fetchBluetoothStatus()` — both need the same timeout/SIGPIPE setup
    /// and the same connect-then-give-up-quietly behavior.
    private static func connectToHelper(readTimeoutSeconds: Int) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

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
        guard var addr = makeUnixSocketAddress(path: bleHelperSocketPath) else {
            close(fd)
            return nil
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func sendRequestAndReadResponse(fd: Int32, request: String) -> Data {
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
        return responseData
    }
}
