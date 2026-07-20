import Foundation

public func parseDeviceIdList(_ output: String) -> [String] {
    output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

public func parseBatteryPlist(_ data: Data) -> (percentage: Int, isCharging: Bool)? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: Any],
          let percentage = dict["BatteryCurrentCapacity"] as? Int
    else {
        return nil
    }
    let isCharging = dict["BatteryIsCharging"] as? Bool ?? false
    return (percentage, isCharging)
}

public func parseDeviceNamePlist(_ data: Data) -> String? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: Any],
          let name = dict["DeviceName"] as? String
    else {
        return nil
    }
    return name
}

public struct IDeviceStatus: Sendable, Equatable {
    public let toolsInstalled: Bool
    /// Count of devices detected but not readable; a catch-all for any per-device fetch failure
    /// (untrusted pairing, malformed battery data, or device disconnected mid-enumeration).
    public let connectedButUnreadableCount: Int
}

/// Pure computation of the lightweight status `checkStatus()` reports, given
/// just the exit code of a single `idevice_id -l` probe (which is all
/// `checkStatus()` runs itself) plus whatever `connectedButUnreadableCount`
/// was most recently observed by a real `fetchAll()`/`fetchAllBlocking()` run
/// elsewhere in the process (0 if none has run yet). Separated out from
/// `IDeviceBatterySource.checkStatus()` so this decision logic is unit
/// testable without spawning a subprocess.
func iDeviceStatus(fromToolsProbeExitCode exitCode: Int32, cachedUnreadableCount: Int) -> IDeviceStatus {
    guard exitCode == 0 else {
        return IDeviceStatus(toolsInstalled: false, connectedButUnreadableCount: 0)
    }
    return IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: cachedUnreadableCount)
}

/// Thread-safe holder for the `connectedButUnreadableCount` most recently
/// computed by a real `IDeviceBatterySource.fetchAllBlocking()` run. Written
/// by `fetchAllBlocking()` (the expensive, full enumeration) and read by the
/// lightweight `checkStatus()`, so `checkStatus()` can report an accurate
/// "connected but unreadable" count without re-running the expensive
/// per-device `ideviceinfo` queries itself. Starts at 0 if `fetchAll()` has
/// never run yet in this process.
final class UnreadableCountCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }
}

public func iDeviceStatusWarning(status: IDeviceStatus) -> String? {
    guard status.toolsInstalled else {
        return "libimobiledevice isn't installed, so iPhone/iPad battery couldn't be checked. Install it with `brew install libimobiledevice`."
    }
    guard status.connectedButUnreadableCount == 0 else {
        let plural = status.connectedButUnreadableCount == 1 ? "device" : "devices"
        return "\(status.connectedButUnreadableCount) connected iOS \(plural) couldn't be read — make sure to trust this computer on the device "
            + "(tap \"Trust\" when prompted after connecting)."
    }
    return nil
}

public struct IDeviceBatterySource: BatteryDataSource {
    /// Populated by `fetchAllBlocking()` on every real enumeration; read back
    /// by `checkStatus()` so it doesn't need to redo that work. Shared across
    /// all `IDeviceBatterySource` instances (there's only ever conceptually
    /// one iOS-device world to enumerate), matching the existing `static`
    /// storage pattern already used for `fetchAllBlocking`/`fetchDeviceInfo`.
    private static let unreadableCountCache = UnreadableCountCache()

    public init() {}

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.fetchAllBlocking().devices)
            }
        }
    }

    /// Lightweight status check for the `_status`/not-found warning paths.
    /// Unlike `fetchAll()`, this does NOT enumerate every connected device's
    /// battery info — it only runs a single `idevice_id -l` call (through the
    /// same watchdog-protected `runSubprocess`) to determine
    /// whether the tools are installed and runnable on `$PATH`. The
    /// "connected but unreadable" count comes from `unreadableCountCache`,
    /// last populated by whichever real `fetchAll()`/`fetchAllBlocking()`
    /// call most recently ran (by the same registry request, in the current
    /// call sites) rather than being recomputed here.
    ///
    /// Kept synchronous (not `async`), same as `BLEBatterySource
    /// .fetchBluetoothStatus()` — its one subprocess call is bounded by
    /// `runSubprocess`'s watchdog timeout, so a bounded blocking
    /// call directly inside the async `CallTool` handler is consistent with
    /// how the existing Bluetooth-status check (bounded by its own socket
    /// read timeout) is already called there.
    public static func checkStatus() -> IDeviceStatus {
        let idResult = runSubprocess("idevice_id", ["-l"])
        return iDeviceStatus(fromToolsProbeExitCode: idResult.exitCode, cachedUnreadableCount: unreadableCountCache.value)
    }

    /// `idevice_id -l` only lists USB-attached devices; a device reachable
    /// solely over WiFi sync (no cable) never appears in that list, and
    /// `ideviceinfo` without `-n` fails with "Device ... not found!" for such
    /// a device even when given its UDID directly — confirmed against a real
    /// iPhone with its USB cable unplugged. `idevice_id -n` lists
    /// network-reachable devices separately; a device connected both ways
    /// appears in both lists, so network results are filtered down to UDIDs
    /// not already found via USB before being queried with `-n`.
    private static func fetchAllBlocking() -> (devices: [DeviceBatteryInfo], status: IDeviceStatus) {
        let usbResult = runSubprocess("idevice_id", ["-l"])
        let networkResult = runSubprocess("idevice_id", ["-n"])
        guard usbResult.exitCode == 0 || networkResult.exitCode == 0 else {
            return ([], IDeviceStatus(toolsInstalled: false, connectedButUnreadableCount: 0))
        }

        let usbUDIDs = usbResult.exitCode == 0
            ? parseDeviceIdList(String(data: usbResult.stdout, encoding: .utf8) ?? "")
            : []
        let networkUDIDs = networkResult.exitCode == 0
            ? parseDeviceIdList(String(data: networkResult.stdout, encoding: .utf8) ?? "")
            : []
        let networkOnlyUDIDs = networkUDIDs.filter { !usbUDIDs.contains($0) }

        var devices: [DeviceBatteryInfo] = []
        for udid in usbUDIDs {
            if let info = fetchDeviceInfo(udid: udid, viaNetwork: false) {
                devices.append(info)
            }
        }
        for udid in networkOnlyUDIDs {
            if let info = fetchDeviceInfo(udid: udid, viaNetwork: true) {
                devices.append(info)
            }
        }

        let totalUDIDCount = usbUDIDs.count + networkOnlyUDIDs.count
        let unreadableCount = totalUDIDCount - devices.count
        unreadableCountCache.value = unreadableCount
        return (devices, IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: unreadableCount))
    }

    private static func fetchDeviceInfo(udid: String, viaNetwork: Bool) -> DeviceBatteryInfo? {
        let baseArgs = viaNetwork ? ["-u", udid, "-n"] : ["-u", udid]

        let batteryResult = runSubprocess("ideviceinfo", baseArgs + ["-q", "com.apple.mobile.battery", "-x"])
        guard batteryResult.exitCode == 0,
              let battery = parseBatteryPlist(batteryResult.stdout)
        else {
            return nil
        }

        let identityResult = runSubprocess("ideviceinfo", baseArgs + ["-x"])
        let name = (identityResult.exitCode == 0 ? parseDeviceNamePlist(identityResult.stdout) : nil) ?? udid

        return DeviceBatteryInfo(
            id: udid,
            name: name,
            kind: .iosDevice,
            percentage: battery.percentage,
            isCharging: battery.isCharging,
            lastUpdated: Date()
        )
    }
}
