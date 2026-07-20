// Sources/IBatteryCore/DataSources/BLEAdvertisementCache.swift
//
// Pure, CoreBluetooth-free state for the helper's advertisement monitor:
// ingests classified manufacturer-data payloads and produces the AirPods
// portion of a "snapshot" response. Kept separate from the CB delegate layer
// so the routing and entry-building logic is unit-testable.
import Foundation

public struct CachedAirPodsState: Equatable, Sendable {
    public let peripheralID: UUID
    public let state: AirPodsAdvertisementState
    public let lastSeen: Date

    public init(peripheralID: UUID, state: AirPodsAdvertisementState, lastSeen: Date) {
        self.peripheralID = peripheralID
        self.state = state
        self.lastSeen = lastSeen
    }
}

private struct ComponentEntry {
    let label: String
    let component: AirPodsComponentState
    let lidOpen: Bool?
}

public struct BLEAdvertisementCache: Equatable, Sendable {
    /// Device display name → latest parsed AirPods state. Keyed by name
    /// because AirPods randomize their BLE MAC; the GAP name is the only
    /// stable cross-advertisement key available here.
    public private(set) var airpods: [String: CachedAirPodsState] = [:]
    /// Device display name → CoreBluetooth peripheral identifier for
    /// peripherals whose advertisements mark them as iOS devices. GATT
    /// reads happen later, at snapshot time, in the monitor layer.
    public private(set) var iosCandidates: [String: UUID] = [:]

    public init() {}

    public mutating func ingest(deviceName: String, peripheralID: UUID, manufacturerData: Data, at now: Date) {
        switch classifyAppleManufacturerData(manufacturerData) {
        case .airpodsOpen:
            if let state = parseAirPodsOpenMessage(manufacturerData) {
                airpods[deviceName] = CachedAirPodsState(peripheralID: peripheralID, state: state, lastSeen: now)
            }
        case .airpodsClose:
            if let state = parseAirPodsCloseMessage(manufacturerData) {
                airpods[deviceName] = CachedAirPodsState(peripheralID: peripheralID, state: state, lastSeen: now)
            }
        case .iosCandidate:
            iosCandidates[deviceName] = peripheralID
        case nil:
            break
        }
    }

    /// The AirPods portion of a snapshot response. Components whose battery
    /// byte was absent (0xff) are omitted — the MCP-side merge falls back to
    /// system_profiler for those. Sorted by name for deterministic output.
    public func airpodsEntries() -> [DeviceBatteryInfo] {
        var results: [DeviceBatteryInfo] = []
        for (name, cached) in airpods.sorted(by: { $0.key < $1.key }) {
            let idBase = "ble-\(cached.peripheralID.uuidString.lowercased())"
            let components: [ComponentEntry] = [
                ComponentEntry(label: "Left", component: cached.state.left, lidOpen: nil),
                ComponentEntry(label: "Right", component: cached.state.right, lidOpen: nil),
                ComponentEntry(label: "Case", component: cached.state.caseComponent, lidOpen: cached.state.lidOpen)
            ]
            for entry in components {
                guard let percentage = entry.component.percentage else { continue }
                results.append(DeviceBatteryInfo(
                    id: "\(idBase)-\(entry.label.lowercased())",
                    name: "\(name) (\(entry.label))",
                    kind: .airpods,
                    percentage: percentage,
                    isCharging: entry.component.isCharging,
                    lastUpdated: cached.lastSeen,
                    inCase: entry.component.inCase,
                    lidOpen: entry.lidOpen
                ))
            }
        }
        return results
    }
}
