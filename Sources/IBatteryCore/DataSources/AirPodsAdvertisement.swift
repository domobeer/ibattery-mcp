// Sources/IBatteryCore/DataSources/AirPodsAdvertisement.swift
//
// Pure parsing of Apple's plaintext BLE manufacturer-data payloads, per the
// byte layout documented in
// docs/superpowers/specs/2026-07-20-ble-advertisement-design.md §3 (derived
// from AirBattery's published protocol analysis and the furiousMAC
// `continuity` research; no code reused). Runs anywhere; only the helper's
// BLEAdvertisementMonitor feeds it live data.
import Foundation

public enum AppleAdvertisementKind: Equatable, Sendable {
    case airpodsOpen
    case airpodsClose
    case iosCandidate
}

/// Classifies a CBAdvertisementDataManufacturerDataKey payload. Returns nil
/// for anything that isn't one of the three Apple message shapes we handle —
/// including Apple payloads of other types, non-Apple company IDs, and
/// too-short data.
public func classifyAppleManufacturerData(_ data: Data) -> AppleAdvertisementKind? {
    let bytes = [UInt8](data)
    guard bytes.count > 2, bytes[0] == 0x4C, bytes[1] == 0x00 else { return nil }
    if bytes.count == 29 && bytes[2] == 0x07 { return .airpodsOpen }
    if bytes.count == 25 && bytes[2] == 0x12 { return .airpodsClose }
    if bytes[2] == 0x10 || bytes[2] == 0x0C { return .iosCandidate }
    return nil
}

public struct AirPodsComponentState: Equatable, Sendable {
    /// nil = component absent from this advertisement (0xff sentinel or
    /// invalid value); the caller falls back to system_profiler's cache.
    public let percentage: Int?
    public let isCharging: Bool?
    /// nil = unknown; never guessed (see the design doc's confidence rules).
    public let inCase: Bool?

    public init(percentage: Int?, isCharging: Bool?, inCase: Bool?) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.inCase = inCase
    }
}

public struct AirPodsAdvertisementState: Equatable, Sendable {
    public let left: AirPodsComponentState
    public let right: AirPodsComponentState
    public let caseComponent: AirPodsComponentState
    public let lidOpen: Bool

    public init(left: AirPodsComponentState, right: AirPodsComponentState, caseComponent: AirPodsComponentState, lidOpen: Bool) {
        self.left = left
        self.right = right
        self.caseComponent = caseComponent
        self.lidOpen = lidOpen
    }
}

/// Battery byte: 0xff = absent; else bit 7 = charging, low 7 bits = level.
/// A level over 100 with no charging bit can't occur in the documented
/// protocol, so it's treated as absent rather than trusted.
private func decodeAirPodsBatteryByte(_ byte: UInt8) -> (percentage: Int, isCharging: Bool)? {
    guard byte != 0xFF else { return nil }
    let level = Int(byte & 0x7F)
    guard level <= 100 else { return nil }
    return (level, byte & 0x80 != 0)
}

/// 29-byte "open" message (type 0x07), broadcast while the lid is open or
/// buds are in use.
public func parseAirPodsOpenMessage(_ data: Data) -> AirPodsAdvertisementState? {
    let bytes = [UInt8](data)
    guard bytes.count == 29, bytes[0] == 0x4C, bytes[1] == 0x00, bytes[2] == 0x07 else { return nil }

    // High-nibble bit 0x02 clear → left/right battery byte positions swapped.
    let flipped = (bytes[7] >> 4) & 0x02 == 0
    let leftBattery = decodeAirPodsBatteryByte(bytes[flipped ? 15 : 14])
    let rightBattery = decodeAirPodsBatteryByte(bytes[flipped ? 14 : 15])
    let caseBattery = decodeAirPodsBatteryByte(bytes[16])

    // Low nibble: 5 = both buds in case (certain); 1 = at least one bud out —
    // then a charging bud is certainly in the case, anything else is unknown.
    let coarseState = bytes[7] & 0x0F
    func inCase(_ battery: (percentage: Int, isCharging: Bool)?) -> Bool? {
        if coarseState == 5 { return true }
        guard coarseState == 1 else { return nil }
        return battery?.isCharging == true ? true : nil
    }

    return AirPodsAdvertisementState(
        left: AirPodsComponentState(percentage: leftBattery?.percentage, isCharging: leftBattery?.isCharging, inCase: inCase(leftBattery)),
        right: AirPodsComponentState(percentage: rightBattery?.percentage, isCharging: rightBattery?.isCharging, inCase: inCase(rightBattery)),
        caseComponent: AirPodsComponentState(percentage: caseBattery?.percentage, isCharging: caseBattery?.isCharging, inCase: nil),
        lidOpen: true
    )
}

/// 25-byte "close" message (type 0x12), broadcast briefly by the case at the
/// moment the lid closes. Byte 4 encodes the exact per-bud state.
public func parseAirPodsCloseMessage(_ data: Data) -> AirPodsAdvertisementState? {
    let bytes = [UInt8](data)
    guard bytes.count == 25, bytes[0] == 0x4C, bytes[1] == 0x00, bytes[2] == 0x12 else { return nil }

    let inCasePair: (left: Bool, right: Bool)?
    switch bytes[4] {
    case 0x2E: inCasePair = (left: true, right: true)
    case 0x2C: inCasePair = (left: false, right: true)   // only left taken out
    case 0x26: inCasePair = (left: true, right: false)   // only right taken out
    case 0x24: inCasePair = (left: false, right: false)
    default: inCasePair = nil                            // unknown value — never guess
    }

    let caseBattery = decodeAirPodsBatteryByte(bytes[12])
    let leftBattery = decodeAirPodsBatteryByte(bytes[13])
    let rightBattery = decodeAirPodsBatteryByte(bytes[14])

    return AirPodsAdvertisementState(
        left: AirPodsComponentState(percentage: leftBattery?.percentage, isCharging: leftBattery?.isCharging, inCase: inCasePair?.left),
        right: AirPodsComponentState(percentage: rightBattery?.percentage, isCharging: rightBattery?.isCharging, inCase: inCasePair?.right),
        caseComponent: AirPodsComponentState(percentage: caseBattery?.percentage, isCharging: caseBattery?.isCharging, inCase: nil),
        lidOpen: false
    )
}
