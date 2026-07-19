import Foundation
import IOKit.ps

public func parseMacBatteryDescription(_ description: [String: Any]) -> DeviceBatteryInfo? {
    guard let capacity = description[kIOPSCurrentCapacityKey as String] as? Int else {
        return nil
    }
    let isCharging = description[kIOPSIsChargingKey as String] as? Bool
    return DeviceBatteryInfo(
        id: "mac-internal-battery",
        name: Host.current().localizedName ?? "This Mac",
        kind: .mac,
        percentage: capacity,
        isCharging: isCharging,
        lastUpdated: Date()
    )
}

public func fetchMacBatteryInfo() -> DeviceBatteryInfo? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
    guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            continue
        }
        guard (description[kIOPSTypeKey as String] as? String) == kIOPSInternalBatteryType else {
            continue
        }
        return parseMacBatteryDescription(description)
    }
    return nil
}

public struct MacBatterySource: BatteryDataSource {
    public init() {}
    public func fetchAll() async -> [DeviceBatteryInfo] {
        if let info = fetchMacBatteryInfo() {
            return [info]
        }
        return []
    }
}
