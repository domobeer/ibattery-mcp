import CLibimobiledevice
import Foundation

public func parseUDIDList(fromPairedDevicesPlist plist: plist_t?) -> [String] {
    guard let plist else { return [] }
    let count = plist_array_get_size(plist)
    var result: [String] = []
    for index in 0..<count {
        guard let item = plist_array_get_item(plist, index) else { continue }
        var cstr: UnsafeMutablePointer<CChar>?
        plist_get_string_val(item, &cstr)
        if let cstr {
            result.append(String(cString: cstr))
            plist_mem_free(cstr)
        }
    }
    return result
}

public func parseWatchBatteryValue(fromCapacityPlist capacityPlist: plist_t?, chargingPlist: plist_t?) -> (percentage: Int, isCharging: Bool)? {
    guard let capacityPlist else { return nil }
    var capacity: UInt64 = 0
    plist_get_uint_val(capacityPlist, &capacity)

    var isCharging = false
    if let chargingPlist {
        var chargingRaw: UInt8 = 0
        plist_get_bool_val(chargingPlist, &chargingRaw)
        isCharging = chargingRaw != 0
    }
    return (Int(capacity), isCharging)
}

public func parseWatchProductType(fromPlist plist: plist_t?) -> String? {
    guard let plist else { return nil }
    var cstr: UnsafeMutablePointer<CChar>?
    plist_get_string_val(plist, &cstr)
    guard let cstr else { return nil }
    defer { plist_mem_free(cstr) }
    return String(cString: cstr)
}

/// Ensures a `CheckedContinuation` racing multiple completion paths (here: the
/// real blocking work vs. a timeout) is resumed at most once. `NSLock`-guarded
/// single-purpose type, matching the existing `UnreadableCountCache` shape in
/// `IDeviceBattery.swift`.
final class SingleResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var alreadyResumed = false

    /// Returns `true` the first time it's called (the caller should resume
    /// the continuation); `false` on every subsequent call (the caller must
    /// not resume — someone else already won the race).
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !alreadyResumed else { return false }
        alreadyResumed = true
        return true
    }
}

public struct WatchBatterySource: BatteryDataSource {
    /// Overall wall-clock deadline for a single `fetchAll()` call.
    ///
    /// Unlike `runLibimobiledeviceTool`'s subprocess watchdog (which can
    /// safely `SIGKILL` a hung child), there's no safe way to cancel a live
    /// `companion_proxy` C call mid-flight from another thread — freeing an
    /// `idevice_t`/`companion_proxy_client_t` while a call using that handle
    /// might still be in progress elsewhere is unsafe. So this bound doesn't
    /// abort `fetchAllBlocking()`; it just stops the caller from waiting on
    /// it. If the timeout wins the race (via `SingleResumeGate`), `fetchAll()`
    /// returns an empty array and the abandoned background work either
    /// finishes harmlessly on its own thread (its result is simply discarded)
    /// or keeps blocking indefinitely on its own — either way nothing is
    /// awaiting it anymore, so it can no longer hang the MCP tool call.
    ///
    /// 15s is chosen to comfortably cover the legitimate multi-device case:
    /// `fetchAllBlocking()` loops over every connected iPhone, and each
    /// iPhone can do up to ~4 `companion_proxy` round-trips per paired watch
    /// (one device-registry fetch per iPhone, plus capacity/charging/product-
    /// type per watch) — while still being a meaningful bound on a stalled
    /// `usbmuxd`/SSL-handshake wait, which has no other guaranteed ceiling.
    private static let overallTimeoutSeconds: TimeInterval = 15.0

    public init() {}

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            let resumeGate = SingleResumeGate()

            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.fetchAllBlocking()
                if resumeGate.tryResume() {
                    continuation.resume(returning: result)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + Self.overallTimeoutSeconds) {
                if resumeGate.tryResume() {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Same USB+network merge as `IDeviceBatterySource.fetchAllBlocking()`:
    /// `idevice_id -l` alone misses an iPhone reachable only over WiFi sync,
    /// which would otherwise hide its paired Watch entirely.
    private static func fetchAllBlocking() -> [DeviceBatteryInfo] {
        let usbResult = runLibimobiledeviceTool("idevice_id", ["-l"])
        let networkResult = runLibimobiledeviceTool("idevice_id", ["-n"])

        let usbUDIDs = usbResult.exitCode == 0
            ? parseDeviceIdList(String(data: usbResult.stdout, encoding: .utf8) ?? "")
            : []
        let networkUDIDs = networkResult.exitCode == 0
            ? parseDeviceIdList(String(data: networkResult.stdout, encoding: .utf8) ?? "")
            : []
        let iphoneUDIDs = usbUDIDs + networkUDIDs.filter { !usbUDIDs.contains($0) }

        var results: [DeviceBatteryInfo] = []
        for iphoneUDID in iphoneUDIDs {
            results.append(contentsOf: fetchWatches(pairedWithIPhoneUDID: iphoneUDID))
        }
        return results
    }

    /// The companion_proxy service closes its connection after replying to
    /// *every* request (`companion_proxy_get_device_registry` and
    /// `companion_proxy_get_value_from_registry` both document this). A
    /// `companion_proxy_client_t` is therefore single-use: reusing one across
    /// calls sends the next request on an already-closed connection, which
    /// fails with `COMPANION_PROXY_E_SSL_ERROR` — confirmed against a real
    /// paired Watch. Every request in this file opens its own short-lived
    /// client instead of sharing one.
    private static func withFreshCompanionClient<T>(
        device: idevice_t,
        _ body: (companion_proxy_client_t) -> T?
    ) -> T? {
        var client: companion_proxy_client_t?
        guard companion_proxy_client_start_service(device, &client, "ibattery-mcp") == COMPANION_PROXY_E_SUCCESS,
              let client
        else {
            return nil
        }
        defer { companion_proxy_client_free(client) }
        return body(client)
    }

    private static func fetchWatches(pairedWithIPhoneUDID iphoneUDID: String) -> [DeviceBatteryInfo] {
        var device: idevice_t?
        let lookupOptions = idevice_options(IDEVICE_LOOKUP_USBMUX.rawValue | IDEVICE_LOOKUP_NETWORK.rawValue)
        guard idevice_new_with_options(&device, iphoneUDID, lookupOptions) == IDEVICE_E_SUCCESS, let device else {
            return []
        }
        defer { idevice_free(device) }

        let watchUDIDs = withFreshCompanionClient(device: device) { client -> [String]? in
            var pairedDevicesPlist: plist_t?
            guard companion_proxy_get_device_registry(client, &pairedDevicesPlist) == COMPANION_PROXY_E_SUCCESS,
                  let pairedDevicesPlist
            else {
                return nil
            }
            defer { plist_free(pairedDevicesPlist) }
            return parseUDIDList(fromPairedDevicesPlist: pairedDevicesPlist)
        } ?? []

        var results: [DeviceBatteryInfo] = []
        for watchUDID in watchUDIDs {
            if let info = fetchWatchBatteryInfo(device: device, watchUDID: watchUDID) {
                results.append(info)
            }
        }
        return results
    }

    /// `companion_proxy_get_value_from_registry` doesn't return the requested
    /// value as a bare scalar: it returns a one-entry dict keyed by the same
    /// key that was requested (e.g. `{"BatteryCurrentCapacity": 100}`,
    /// confirmed against a real paired Watch via `plist_to_xml`). This
    /// unwraps that envelope and returns an independently-owned copy of the
    /// inner node, since the envelope dict is freed before returning.
    private static func fetchRegistryValue(device: idevice_t, watchUDID: String, key: String) -> plist_t? {
        let envelope = withFreshCompanionClient(device: device) { client -> plist_t? in
            var valuePlist: plist_t?
            guard companion_proxy_get_value_from_registry(client, watchUDID, key, &valuePlist) == COMPANION_PROXY_E_SUCCESS,
                  let valuePlist
            else {
                return nil
            }
            return valuePlist
        }
        guard let envelope else { return nil }
        defer { plist_free(envelope) }
        guard let inner = plist_dict_get_item(envelope, key) else { return nil }
        return plist_copy(inner)
    }

    private static func fetchWatchBatteryInfo(device: idevice_t, watchUDID: String) -> DeviceBatteryInfo? {
        guard let capacityPlist = fetchRegistryValue(device: device, watchUDID: watchUDID, key: "BatteryCurrentCapacity") else {
            return nil
        }
        defer { plist_free(capacityPlist) }

        let chargingPlist = fetchRegistryValue(device: device, watchUDID: watchUDID, key: "BatteryIsCharging")
        defer { if let chargingPlist { plist_free(chargingPlist) } }

        guard let battery = parseWatchBatteryValue(fromCapacityPlist: capacityPlist, chargingPlist: chargingPlist) else {
            return nil
        }

        let productTypePlist = fetchRegistryValue(device: device, watchUDID: watchUDID, key: "ProductType")
        defer { if let productTypePlist { plist_free(productTypePlist) } }
        let name = parseWatchProductType(fromPlist: productTypePlist) ?? watchUDID

        return DeviceBatteryInfo(
            id: watchUDID,
            name: name,
            kind: .watch,
            percentage: battery.percentage,
            isCharging: battery.isCharging,
            lastUpdated: Date()
        )
    }
}
