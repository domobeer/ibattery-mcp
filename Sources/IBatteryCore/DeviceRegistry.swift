import Foundation

public protocol BatteryDataSource: Sendable {
    func fetchAll() async -> [DeviceBatteryInfo]
}

public func markStaleIfNeeded(_ device: DeviceBatteryInfo, now: Date, threshold: TimeInterval = 120) -> DeviceBatteryInfo {
    guard !device.stale, now.timeIntervalSince(device.lastUpdated) > threshold else {
        return device
    }
    return DeviceBatteryInfo(
        id: device.id,
        name: device.name,
        kind: device.kind,
        percentage: device.percentage,
        isCharging: device.isCharging,
        lastUpdated: device.lastUpdated,
        stale: true
    )
}

public actor DeviceRegistry {
    private let sources: [BatteryDataSource]
    private var cache: [String: DeviceBatteryInfo] = [:]

    public init(sources: [BatteryDataSource]) {
        self.sources = sources
    }

    public func getAllDevicesStatus() async -> [DeviceBatteryInfo] {
        var results: [DeviceBatteryInfo] = []
        for source in sources {
            results.append(contentsOf: await source.fetchAll())
        }
        for device in results {
            cache[device.id] = device
        }
        return results
    }

    public func getDeviceBattery(query: String) async -> DeviceBatteryInfo? {
        let all = await getAllDevicesStatus()
        let lowerQuery = query.lowercased()
        return all.first { $0.name.lowercased().contains(lowerQuery) }
    }

    public func listKnownDevices() async -> [DeviceBatteryInfo] {
        let now = Date()
        return cache.values.map { markStaleIfNeeded($0, now: now) }
    }
}
