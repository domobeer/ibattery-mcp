# BLE Advertisement Parsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AirPods real-time battery/charging/in-case status via plaintext BLE advertisement parsing, and locked-iPhone battery via BLE GATT reads — per the approved spec `docs/superpowers/specs/2026-07-20-ble-advertisement-design.md`.

**Architecture:** A persistent `BLEAdvertisementMonitor` inside the existing `ibattery-ble-helper` periodically scans all BLE advertisements, parses AirPods Proximity Pairing messages into an in-memory cache, and remembers iOS-device candidates. A new `"snapshot"` IPC request returns cached AirPods entries plus on-demand GATT battery reads of the candidates. On the MCP side a new `BLESnapshotSource` fetches the snapshot and a pure merge pass in `DeviceRegistry` reconciles it with the `system_profiler` and libimobiledevice sources.

**Tech Stack:** Swift 5.9 SPM package, XCTest, CoreBluetooth (helper process only), Unix domain socket IPC (existing).

## Global Constraints

- macOS 13+ (`Package.swift` platform floor); swift-tools 5.9.
- Tests are XCTest in `Tests/IBatteryCoreTests/`, `@testable import IBatteryCore`.
- All advertisement parsing is pure public functions in `Sources/IBatteryCore/DataSources/` — unit-testable without CoreBluetooth. CoreBluetooth delegate layers stay thin and have no unit tests (existing `BLEBatteryScanner` precedent).
- No real MAC addresses, serial numbers, or device UDIDs in test fixtures — synthesized bytes only.
- SwiftLint must stay clean: run `swiftlint` from repo root after each task; `line_length` warning threshold is 160.
- `swift test` must pass at every commit.
- Helper changes only take effect after `./Scripts/build-ble-helper-app.sh` + relaunching the app (`pkill -x ibattery-ble-helper; open .build/ibattery-ble-helper.app`).
- Wire format between helper and MCP is `[DeviceBatteryInfo]` encoded with `deviceJSONEncoder` (ISO8601 dates, sorted keys) — both sides live in `IBatteryCore`.
- Commit message style: short imperative subject, matching `git log` history.

---

### Task 1: `DeviceBatteryInfo` gains `inCase` / `lidOpen`

**Files:**
- Modify: `Sources/IBatteryCore/DeviceBatteryInfo.swift`
- Modify: `Sources/IBatteryCore/DeviceRegistry.swift` (`markStaleIfNeeded` must preserve the new fields)
- Test: `Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift`, `Tests/IBatteryCoreTests/StalenessTests.swift`

**Interfaces:**
- Produces: `DeviceBatteryInfo.init(id:name:kind:percentage:isCharging:lastUpdated:stale:inCase:lidOpen:)` with `inCase: Bool? = nil`, `lidOpen: Bool? = nil` (all existing call sites keep compiling via defaults); properties `inCase: Bool?`, `lidOpen: Bool?`. JSON: keys omitted when `nil` (`encodeIfPresent`), decoded with `decodeIfPresent` (legacy payloads without the keys must decode to `nil`).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift` (inside the existing class):

```swift
    func testEncode_omitsInCaseAndLidOpenKeysWhenNil() throws {
        let info = DeviceBatteryInfo(
            id: "x", name: "X", kind: .airpods, percentage: 50,
            isCharging: nil, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let json = String(data: try deviceJSONEncoder.encode(info), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("inCase"))
        XCTAssertFalse(json.contains("lidOpen"))
    }

    func testEncode_includesInCaseAndLidOpenWhenSet() throws {
        let info = DeviceBatteryInfo(
            id: "x", name: "X", kind: .airpods, percentage: 50,
            isCharging: true, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            inCase: true, lidOpen: false
        )
        let json = String(data: try deviceJSONEncoder.encode(info), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"inCase\":true"))
        XCTAssertTrue(json.contains("\"lidOpen\":false"))
    }

    func testDecode_legacyJSONWithoutInCaseKeys_decodesWithNil() throws {
        let json = """
        {"id":"abc","name":"Pods (Left)","kind":"airpods","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z","stale":false}
        """
        let decoded = try deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: Data(json.utf8))
        XCTAssertNil(decoded.inCase)
        XCTAssertNil(decoded.lidOpen)
    }

    func testCodableRoundTrip_preservesInCaseAndLidOpen() throws {
        let info = DeviceBatteryInfo(
            id: "x", name: "X", kind: .airpods, percentage: 50,
            isCharging: false, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            inCase: false, lidOpen: true
        )
        let decoded = try deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: deviceJSONEncoder.encode(info))
        XCTAssertEqual(decoded.inCase, false)
        XCTAssertEqual(decoded.lidOpen, true)
    }
```

Append to `Tests/IBatteryCoreTests/StalenessTests.swift` (inside the existing class):

```swift
    func testMarkStaleIfNeeded_preservesInCaseAndLidOpen() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let device = DeviceBatteryInfo(
            id: "x", name: "X", kind: .airpods, percentage: 50,
            isCharging: nil, lastUpdated: old, inCase: true, lidOpen: false
        )
        let marked = markStaleIfNeeded(device, now: old.addingTimeInterval(500))
        XCTAssertTrue(marked.stale)
        XCTAssertEqual(marked.inCase, true)
        XCTAssertEqual(marked.lidOpen, false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DeviceBatteryInfoTests 2>&1 | tail -20`
Expected: compile error — `extra arguments 'inCase', 'lidOpen' in call` (the fields don't exist yet).

- [ ] **Step 3: Implement the fields**

In `Sources/IBatteryCore/DeviceBatteryInfo.swift`:

Add after `public let stale: Bool`:

```swift
    /// Whether this earbud is currently inside its charging case, when known
    /// from a parsed BLE advertisement. Only ever set on `.airpods`
    /// left/right-bud entries; `nil` means unknown (never guessed — see the
    /// design doc's confidence rules).
    public let inCase: Bool?
    /// Whether the AirPods case lid was open in the most recent advertisement
    /// seen. Only ever set on `.airpods` case entries; `nil` means unknown.
    public let lidOpen: Bool?
```

Replace the initializer with:

```swift
    public init(
        id: String,
        name: String,
        kind: Kind,
        percentage: Int,
        isCharging: Bool?,
        lastUpdated: Date,
        stale: Bool = false,
        inCase: Bool? = nil,
        lidOpen: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percentage = percentage
        self.isCharging = isCharging
        self.lastUpdated = lastUpdated
        self.lastUpdatedLocal = Self.formatLocal(lastUpdated)
        self.stale = stale
        self.inCase = inCase
        self.lidOpen = lidOpen
    }
```

Update `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, percentage, isCharging, lastUpdated, lastUpdatedLocal, stale, inCase, lidOpen
    }
```

In `init(from:)`, add before the `lastUpdatedLocal` line:

```swift
        inCase = try container.decodeIfPresent(Bool.self, forKey: .inCase)
        lidOpen = try container.decodeIfPresent(Bool.self, forKey: .lidOpen)
```

In `encode(to:)`, add after the `stale` line (note: `encodeIfPresent`, unlike `isCharging`'s `encode`, so the keys are *omitted* — not `null` — when unset; the design doc requires omission and legacy decoders tolerate it):

```swift
        try container.encodeIfPresent(inCase, forKey: .inCase)
        try container.encodeIfPresent(lidOpen, forKey: .lidOpen)
```

In `Sources/IBatteryCore/DeviceRegistry.swift`, replace `markStaleIfNeeded`'s rebuild with:

```swift
    return DeviceBatteryInfo(
        id: device.id,
        name: device.name,
        kind: device.kind,
        percentage: device.percentage,
        isCharging: device.isCharging,
        lastUpdated: device.lastUpdated,
        stale: true,
        inCase: device.inCase,
        lidOpen: device.lidOpen
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass (existing suites too — the defaulted parameters keep every call site working).

- [ ] **Step 5: Lint and commit**

```bash
swiftlint
git add Sources/IBatteryCore/DeviceBatteryInfo.swift Sources/IBatteryCore/DeviceRegistry.swift Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift Tests/IBatteryCoreTests/StalenessTests.swift
git commit -m "Add optional inCase/lidOpen fields to DeviceBatteryInfo"
```

---

### Task 2: AirPods advertisement parsing (pure functions)

**Files:**
- Create: `Sources/IBatteryCore/DataSources/AirPodsAdvertisement.swift`
- Test: `Tests/IBatteryCoreTests/AirPodsAdvertisementTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `enum AppleAdvertisementKind: Equatable { case airpodsOpen, airpodsClose, iosCandidate }`
  - `func classifyAppleManufacturerData(_ data: Data) -> AppleAdvertisementKind?`
  - `struct AirPodsComponentState: Equatable, Sendable { let percentage: Int?; let isCharging: Bool?; let inCase: Bool? }`
  - `struct AirPodsAdvertisementState: Equatable, Sendable { let left: AirPodsComponentState; let right: AirPodsComponentState; let caseComponent: AirPodsComponentState; let lidOpen: Bool }`
  - `func parseAirPodsOpenMessage(_ data: Data) -> AirPodsAdvertisementState?`
  - `func parseAirPodsCloseMessage(_ data: Data) -> AirPodsAdvertisementState?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/IBatteryCoreTests/AirPodsAdvertisementTests.swift`:

```swift
// Tests/IBatteryCoreTests/AirPodsAdvertisementTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class AirPodsAdvertisementTests: XCTestCase {
    // Synthesized fixtures per the byte layout in
    // docs/superpowers/specs/2026-07-20-ble-advertisement-design.md §3.
    // Battery byte encoding: 0xff = absent; else bit 7 = charging,
    // low 7 bits = percentage.

    /// flipBitSet=true → byte 7 high nibble carries 0x02 → NOT flipped
    /// (left at 14, right at 15). flipBitSet=false → flipped (swapped).
    private func makeOpenMessage(
        coarseNibble: UInt8,
        flipBitSet: Bool = true,
        byte14: UInt8,
        byte15: UInt8,
        caseByte: UInt8
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x07
        bytes[7] = (flipBitSet ? 0x20 : 0x00) | (coarseNibble & 0x0F)
        bytes[14] = byte14
        bytes[15] = byte15
        bytes[16] = caseByte
        return Data(bytes)
    }

    private func makeCloseMessage(
        stateByte: UInt8,
        caseByte: UInt8,
        leftByte: UInt8,
        rightByte: UInt8
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 25)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x12
        bytes[4] = stateByte
        bytes[12] = caseByte
        bytes[13] = leftByte
        bytes[14] = rightByte
        return Data(bytes)
    }

    // MARK: classification

    func testClassify_openMessage() {
        XCTAssertEqual(classifyAppleManufacturerData(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x40, caseByte: 0x40)), .airpodsOpen)
    }

    func testClassify_closeMessage() {
        XCTAssertEqual(classifyAppleManufacturerData(makeCloseMessage(stateByte: 0x2E, caseByte: 0x40, leftByte: 0x40, rightByte: 0x40)), .airpodsClose)
    }

    func testClassify_iosCandidateTypes() {
        for typeByte: UInt8 in [0x10, 0x0C] {
            let data = Data([0x4C, 0x00, typeByte, 0x00, 0x00])
            XCTAssertEqual(classifyAppleManufacturerData(data), .iosCandidate)
        }
    }

    func testClassify_nonAppleCompanyID_returnsNil() {
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4D, 0x00, 0x07])))
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x01, 0x07])))
    }

    func testClassify_tooShort_returnsNil() {
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x00])))
        XCTAssertNil(classifyAppleManufacturerData(Data()))
    }

    func testClassify_airpodsTypeWithWrongLength_returnsNil() {
        // type 0x07 but not 29 bytes; type 0x12 but not 25 bytes
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x00, 0x07, 0x00])))
        XCTAssertNil(classifyAppleManufacturerData(Data([0x4C, 0x00, 0x12, 0x00])))
    }

    // MARK: battery byte decoding (via the parsers)

    func testOpen_batteryBytes_levelAndCharging() {
        // 0x40 = 64%, not charging; 0x85 = 5%, charging
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x85, caseByte: 0xE4))
        XCTAssertEqual(state?.left.percentage, 64)
        XCTAssertEqual(state?.left.isCharging, false)
        XCTAssertEqual(state?.right.percentage, 5)
        XCTAssertEqual(state?.right.isCharging, true)
        XCTAssertEqual(state?.caseComponent.percentage, 100) // 0xE4 & 0x7F
        XCTAssertEqual(state?.caseComponent.isCharging, true)
    }

    func testOpen_ffByte_componentAbsent() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 1, byte14: 0xFF, byte15: 0x40, caseByte: 0xFF))
        XCTAssertNil(state?.left.percentage)
        XCTAssertNil(state?.left.isCharging)
        XCTAssertEqual(state?.right.percentage, 64)
        XCTAssertNil(state?.caseComponent.percentage)
    }

    func testOpen_invalidLevelOver100NotCharging_componentAbsent() {
        // 0x7F = 127 with charging bit clear — impossible level, treat as absent
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x7F, byte15: 0x40, caseByte: 0x40))
        XCTAssertNil(state?.left.percentage)
    }

    // MARK: open-message in-case confidence rules

    func testOpen_nibble5_bothBudsInCase() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x40, caseByte: 0x40))
        XCTAssertEqual(state?.left.inCase, true)
        XCTAssertEqual(state?.right.inCase, true)
        XCTAssertNil(state?.caseComponent.inCase)
        XCTAssertEqual(state?.lidOpen, true)
    }

    func testOpen_nibble1_chargingBudIsInCase_otherUnknown() {
        // left charging → certainly in case; right not charging → unknown
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 1, byte14: 0x85, byte15: 0x40, caseByte: 0x40))
        XCTAssertEqual(state?.left.inCase, true)
        XCTAssertNil(state?.right.inCase)
    }

    func testOpen_unknownNibble_inCaseUnknown() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 3, byte14: 0x40, byte15: 0x40, caseByte: 0x40))
        XCTAssertNil(state?.left.inCase)
        XCTAssertNil(state?.right.inCase)
    }

    func testOpen_flipBitClear_swapsLeftAndRightBytes() {
        let state = parseAirPodsOpenMessage(makeOpenMessage(coarseNibble: 5, flipBitSet: false, byte14: 0x0A, byte15: 0x14, caseByte: 0x40))
        // flipped: left comes from byte 15 (0x14 = 20%), right from byte 14 (0x0A = 10%)
        XCTAssertEqual(state?.left.percentage, 20)
        XCTAssertEqual(state?.right.percentage, 10)
    }

    // MARK: close-message parsing

    func testClose_stateByteVariants() {
        let cases: [(UInt8, Bool?, Bool?)] = [
            (0x2E, true, true),   // both in case
            (0x2C, false, true),  // only left taken out
            (0x26, true, false),  // only right taken out
            (0x24, false, false), // both out
            (0x99, nil, nil)      // unknown value → never guess
        ]
        for (stateByte, expectedLeft, expectedRight) in cases {
            let state = parseAirPodsCloseMessage(makeCloseMessage(stateByte: stateByte, caseByte: 0x40, leftByte: 0x40, rightByte: 0x40))
            XCTAssertEqual(state?.left.inCase, expectedLeft, "state byte \(stateByte)")
            XCTAssertEqual(state?.right.inCase, expectedRight, "state byte \(stateByte)")
        }
    }

    func testClose_batteryByteMapping_andLidClosed() {
        let state = parseAirPodsCloseMessage(makeCloseMessage(stateByte: 0x2E, caseByte: 0xC8, leftByte: 0x32, rightByte: 0x3C))
        XCTAssertEqual(state?.caseComponent.percentage, 72) // 0xC8 & 0x7F
        XCTAssertEqual(state?.caseComponent.isCharging, true)
        XCTAssertEqual(state?.left.percentage, 50)
        XCTAssertEqual(state?.right.percentage, 60)
        XCTAssertEqual(state?.lidOpen, false)
    }

    func testParsers_rejectWrongShape() {
        XCTAssertNil(parseAirPodsOpenMessage(makeCloseMessage(stateByte: 0x2E, caseByte: 0x40, leftByte: 0x40, rightByte: 0x40)))
        XCTAssertNil(parseAirPodsCloseMessage(makeOpenMessage(coarseNibble: 5, byte14: 0x40, byte15: 0x40, caseByte: 0x40)))
        XCTAssertNil(parseAirPodsOpenMessage(Data()))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AirPodsAdvertisementTests 2>&1 | tail -10`
Expected: compile error — `cannot find 'classifyAppleManufacturerData' in scope`.

- [ ] **Step 3: Implement the parsers**

Create `Sources/IBatteryCore/DataSources/AirPodsAdvertisement.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AirPodsAdvertisementTests 2>&1 | tail -5`
Expected: all AirPodsAdvertisementTests pass.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint
git add Sources/IBatteryCore/DataSources/AirPodsAdvertisement.swift Tests/IBatteryCoreTests/AirPodsAdvertisementTests.swift
git commit -m "Parse AirPods open/close BLE advertisements with in-case confidence rules"
```

---

### Task 3: Advertisement cache (pure state)

**Files:**
- Create: `Sources/IBatteryCore/DataSources/BLEAdvertisementCache.swift`
- Test: `Tests/IBatteryCoreTests/BLEAdvertisementCacheTests.swift`

**Interfaces:**
- Consumes: `classifyAppleManufacturerData`, `parseAirPodsOpenMessage`, `parseAirPodsCloseMessage`, `AirPodsAdvertisementState` (Task 2); `DeviceBatteryInfo` with `inCase`/`lidOpen` (Task 1).
- Produces:
  - `struct CachedAirPodsState: Equatable, Sendable { let peripheralID: UUID; let state: AirPodsAdvertisementState; let lastSeen: Date }`
  - `struct BLEAdvertisementCache: Equatable, Sendable` with `private(set) var airpods: [String: CachedAirPodsState]`, `private(set) var iosCandidates: [String: UUID]` (device name → peripheral identifier), `mutating func ingest(deviceName:peripheralID:manufacturerData:at:)`, `func airpodsEntries() -> [DeviceBatteryInfo]`.
  - Snapshot-entry id convention consumed by Task 5's merge: `"ble-<peripheral-uuid-lowercased>-left/-right/-case"`, names `"<device name> (Left)"` etc. — matching `AirPodsBattery.swift`'s suffix convention exactly.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IBatteryCoreTests/BLEAdvertisementCacheTests.swift`:

```swift
// Tests/IBatteryCoreTests/BLEAdvertisementCacheTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLEAdvertisementCacheTests: XCTestCase {
    private let podsID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let phoneID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func openMessage(left: UInt8 = 0x40, right: UInt8 = 0x3C, caseByte: UInt8 = 0xC8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0x4C; bytes[1] = 0x00; bytes[2] = 0x07
        bytes[7] = 0x20 | 0x05 // flip bit set (no swap), both buds in case
        bytes[14] = left; bytes[15] = right; bytes[16] = caseByte
        return Data(bytes)
    }

    private func closeMessage() -> Data {
        var bytes = [UInt8](repeating: 0, count: 25)
        bytes[0] = 0x4C; bytes[1] = 0x00; bytes[2] = 0x12
        bytes[4] = 0x2C // only left taken out
        bytes[12] = 0x40; bytes[13] = 0x32; bytes[14] = 0x3C
        return Data(bytes)
    }

    func testIngestOpenMessage_producesThreeEntriesWithSuffixesAndFields() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: openMessage(), at: now)

        let entries = cache.airpodsEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.name).sorted(), ["Test Pods (Case)", "Test Pods (Left)", "Test Pods (Right)"])

        let left = entries.first { $0.name == "Test Pods (Left)" }
        XCTAssertEqual(left?.id, "ble-\(podsID.uuidString.lowercased())-left")
        XCTAssertEqual(left?.kind, .airpods)
        XCTAssertEqual(left?.percentage, 64)
        XCTAssertEqual(left?.isCharging, false)
        XCTAssertEqual(left?.inCase, true)
        XCTAssertNil(left?.lidOpen)
        XCTAssertEqual(left?.lastUpdated, now)

        let caseEntry = entries.first { $0.name == "Test Pods (Case)" }
        XCTAssertEqual(caseEntry?.percentage, 72)
        XCTAssertEqual(caseEntry?.isCharging, true)
        XCTAssertEqual(caseEntry?.lidOpen, true)
        XCTAssertNil(caseEntry?.inCase)
    }

    func testIngestCloseMessage_overwritesPreviousState() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: openMessage(), at: now)
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: closeMessage(), at: now.addingTimeInterval(60))

        let entries = cache.airpodsEntries()
        let left = entries.first { $0.name == "Test Pods (Left)" }
        XCTAssertEqual(left?.inCase, false) // close message: only left taken out
        XCTAssertEqual(left?.lastUpdated, now.addingTimeInterval(60))
        let caseEntry = entries.first { $0.name == "Test Pods (Case)" }
        XCTAssertEqual(caseEntry?.lidOpen, false)
    }

    func testIngestFFComponent_omitsThatEntry() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test Pods", peripheralID: podsID, manufacturerData: openMessage(left: 0xFF), at: now)
        let names = cache.airpodsEntries().map(\.name)
        XCTAssertFalse(names.contains("Test Pods (Left)"))
        XCTAssertTrue(names.contains("Test Pods (Right)"))
    }

    func testIngestIOSCandidate_recordsPeripheralID() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Test iPhone", peripheralID: phoneID, manufacturerData: Data([0x4C, 0x00, 0x10, 0x00]), at: now)
        XCTAssertEqual(cache.iosCandidates["Test iPhone"], phoneID)
        XCTAssertTrue(cache.airpodsEntries().isEmpty)
    }

    func testIngestUnrecognizedData_isIgnored() {
        var cache = BLEAdvertisementCache()
        cache.ingest(deviceName: "Mystery", peripheralID: phoneID, manufacturerData: Data([0x99, 0x00, 0x07]), at: now)
        XCTAssertTrue(cache.airpodsEntries().isEmpty)
        XCTAssertTrue(cache.iosCandidates.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BLEAdvertisementCacheTests 2>&1 | tail -10`
Expected: compile error — `cannot find 'BLEAdvertisementCache' in scope`.

- [ ] **Step 3: Implement the cache**

Create `Sources/IBatteryCore/DataSources/BLEAdvertisementCache.swift`:

```swift
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
            let components: [(label: String, component: AirPodsComponentState, lidOpen: Bool?)] = [
                (label: "Left", component: cached.state.left, lidOpen: nil),
                (label: "Right", component: cached.state.right, lidOpen: nil),
                (label: "Case", component: cached.state.caseComponent, lidOpen: cached.state.lidOpen)
            ]
            for (label, component, lidOpen) in components {
                guard let percentage = component.percentage else { continue }
                results.append(DeviceBatteryInfo(
                    id: "\(idBase)-\(label.lowercased())",
                    name: "\(name) (\(label))",
                    kind: .airpods,
                    percentage: percentage,
                    isCharging: component.isCharging,
                    lastUpdated: cached.lastSeen,
                    inCase: component.inCase,
                    lidOpen: lidOpen
                ))
            }
        }
        return results
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BLEAdvertisementCacheTests 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint
git add Sources/IBatteryCore/DataSources/BLEAdvertisementCache.swift Tests/IBatteryCoreTests/BLEAdvertisementCacheTests.swift
git commit -m "Add BLE advertisement cache producing AirPods snapshot entries"
```

---

### Task 4: `BLEAdvertisementMonitor` + helper `"snapshot"` request

**Files:**
- Create: `Sources/IBatteryCore/DataSources/BLEAdvertisementMonitor.swift`
- Modify: `Sources/ibattery-ble-helper/main.swift`

**Interfaces:**
- Consumes: `BLEAdvertisementCache` (Task 3), `batteryServiceUUID`, `batteryLevelCharacteristicUUID`, `parseBatteryLevelCharacteristic` (existing in `BLEBattery.swift`), `deviceJSONEncoder`.
- Produces: `final class BLEAdvertisementMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate` with `func start()` (call once from the main queue) and `func snapshot() async -> [DeviceBatteryInfo]`. Wire behavior consumed by Task 5: `"snapshot\n"` request over the existing Unix socket returns `deviceJSONEncoder`-encoded `[DeviceBatteryInfo]` + trailing newline.

This layer is deliberately thin and has **no unit tests** (CoreBluetooth delegate code, same policy as `BLEBatteryScanner`); Step 4 verifies it manually. Design deviations locked in here, both YAGNI per spec §3/§5: the open-message model-ID pair is not parsed (display name comes from `peripheral.name`), and the `2A29` vendor characteristic is not read (`2A24` model alone drives the Watch exclusion).

- [ ] **Step 1: Implement the monitor**

Create `Sources/IBatteryCore/DataSources/BLEAdvertisementMonitor.swift`:

```swift
// Sources/IBatteryCore/DataSources/BLEAdvertisementMonitor.swift
//
// Runs only inside ibattery-ble-helper. Periodically passive-scans all BLE
// advertisements (AirPods stop broadcasting shortly after their lid closes,
// so an on-demand scan would miss the lid-close message that carries the
// exact per-bud in-case state — continuous listening is what catches it),
// feeds them to BLEAdvertisementCache, and serves the "snapshot" IPC
// request: cached AirPods entries plus a bounded GATT battery read of every
// remembered iOS-device candidate. All state is confined to the main queue:
// the CBCentralManager is created with queue: .main and snapshot() hops to
// the main queue before touching anything.
import CoreBluetooth
import Foundation

let deviceInformationServiceUUID = CBUUID(string: "180A")
let modelNumberCharacteristicUUID = CBUUID(string: "2A24")

public final class BLEAdvertisementMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager?
    private var cache = BLEAdvertisementCache()
    private var candidatePeripherals: [UUID: CBPeripheral] = [:]
    private var scanTimer: Timer?

    private let initialScanDuration: TimeInterval = 15
    private let periodicScanDuration: TimeInterval = 5
    private let scanInterval: TimeInterval = 30
    private let perDeviceGATTTimeout: TimeInterval = 5
    private let totalGATTTimeout: TimeInterval = 10

    // In-flight GATT snapshot state (main queue only). One snapshot at a
    // time: a second concurrent request gets [] for the iOS portion rather
    // than corrupting the first one's bookkeeping.
    private var gattCompletion: (([DeviceBatteryInfo]) -> Void)?
    private var gattPending: Set<UUID> = []
    private var gattLevels: [UUID: Int] = [:]
    private var gattModels: [UUID: String] = [:]
    private var gattNames: [UUID: String] = [:]

    /// Call once at helper startup, from the main queue.
    public func start() {
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            scanTimer?.invalidate()
            scanTimer = nil
            return
        }
        beginScan(duration: initialScanDuration)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.beginScan(duration: self.periodicScanDuration)
        }
    }

    private func beginScan(duration: TimeInterval) {
        guard let central = centralManager, central.state == .poweredOn, !central.isScanning else { return }
        // Allow duplicates so a mid-window state change (e.g. the one-shot
        // lid-close message right after an open message from the same
        // peripheral) isn't coalesced away.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.centralManager?.stopScan()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let name = peripheral.name,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        else { return }
        cache.ingest(deviceName: name, peripheralID: peripheral.identifier, manufacturerData: data, at: Date())
        // Retain the CBPeripheral for iOS candidates — connect() needs the
        // object, not just its identifier.
        if cache.iosCandidates[name] == peripheral.identifier {
            candidatePeripherals[peripheral.identifier] = peripheral
        }
    }

    /// Serves the helper's "snapshot" IPC request.
    public func snapshot() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let airpods = self.cache.airpodsEntries()
                self.startGATTReads { iosDevices in
                    continuation.resume(returning: airpods + iosDevices)
                }
            }
        }
    }

    // MARK: - GATT reads of iOS candidates (main queue only)

    private func startGATTReads(completion: @escaping ([DeviceBatteryInfo]) -> Void) {
        let peripherals = Array(candidatePeripherals.values)
        guard !peripherals.isEmpty,
              let central = centralManager, central.state == .poweredOn,
              gattCompletion == nil
        else {
            completion([])
            return
        }
        gattCompletion = completion
        gattPending = Set(peripherals.map(\.identifier))
        gattLevels = [:]
        gattModels = [:]
        gattNames = [:]
        for peripheral in peripherals {
            gattNames[peripheral.identifier] = peripheral.name
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            let id = peripheral.identifier
            DispatchQueue.main.asyncAfter(deadline: .now() + perDeviceGATTTimeout) { [weak self] in
                self?.finishCandidate(id, cancel: peripheral)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + totalGATTTimeout) { [weak self] in
            self?.finishAllCandidates()
        }
    }

    private func finishCandidate(_ id: UUID, cancel peripheral: CBPeripheral? = nil) {
        guard gattPending.contains(id) else { return }
        gattPending.remove(id)
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        if gattPending.isEmpty {
            finishAllCandidates()
        }
    }

    private func finishAllCandidates() {
        guard let completion = gattCompletion else { return }
        gattCompletion = nil
        gattPending = []
        var results: [DeviceBatteryInfo] = []
        let now = Date()
        for (id, level) in gattLevels.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            // Apple Watch exclusion: its GATT battery is not reliable
            // (AirBattery applies the same exclusion). A device that never
            // reported a model string is kept — the filter only drops
            // confirmed Watches.
            if let model = gattModels[id], model.contains("Watch") { continue }
            results.append(DeviceBatteryInfo(
                id: "ble-\(id.uuidString.lowercased())",
                name: gattNames[id] ?? "Unknown iOS Device",
                kind: .iosDevice,
                percentage: level,
                isCharging: nil,
                lastUpdated: now
            ))
        }
        completion(results)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryServiceUUID, deviceInformationServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishCandidate(peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            finishCandidate(peripheral.identifier, cancel: peripheral)
            return
        }
        for service in services {
            if service.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelCharacteristicUUID], for: service)
            } else if service.uuid == deviceInformationServiceUUID {
                peripheral.discoverCharacteristics([modelNumberCharacteristicUUID], for: service)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            peripheral.readValue(for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        if characteristic.uuid == batteryLevelCharacteristicUUID,
           let data = characteristic.value,
           let level = parseBatteryLevelCharacteristic(data) {
            gattLevels[id] = level
        }
        if characteristic.uuid == modelNumberCharacteristicUUID, let data = characteristic.value {
            gattModels[id] = String(data: data, encoding: .ascii) ?? ""
        }
        if gattLevels[id] != nil && gattModels[id] != nil {
            finishCandidate(id, cancel: peripheral)
        }
    }
}
```

- [ ] **Step 2: Wire the monitor into the helper**

In `Sources/ibattery-ble-helper/main.swift`:

After the `signal(SIGPIPE, SIG_IGN)` line, add:

```swift
// Persistent advertisement monitor — starts its periodic passive scan as
// soon as Bluetooth is powered on and keeps the AirPods/iOS-candidate cache
// warm for "snapshot" requests. Created on the main thread; all of its
// state lives on the main queue (see BLEAdvertisementMonitor).
let advertisementMonitor = BLEAdvertisementMonitor()
Task { @MainActor in
    advertisementMonitor.start()
}
```

In the request-dispatch `Task { @MainActor in ... }`, replace:

```swift
            if requestText == "status" {
```
…keep that branch unchanged, and insert a new branch before the final `else`:

```swift
            } else if requestText == "snapshot" {
                // Cached AirPods advertisement state + bounded GATT battery
                // reads of remembered iOS-device candidates. See
                // BLEAdvertisementMonitor.
                let devices = await advertisementMonitor.snapshot()
                responseData = (try? deviceJSONEncoder.encode(devices)) ?? Data("[]".utf8)
            } else {
```

(The final `else` — "scan or anything else" — keeps its existing comment and body. Old MCP clients never send `"snapshot"`, and a *new* MCP client talking to an *old* helper falls into the old helper's scan branch, which Task 5's merge tolerates by design.)

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds; all existing tests still pass (no unit tests were added in this task).

- [ ] **Step 4: Manual smoke test against the real helper**

```bash
./Scripts/build-ble-helper-app.sh
pkill -x ibattery-ble-helper || true
open .build/ibattery-ble-helper.app
sleep 20   # let the initial 15s scan complete
printf 'snapshot\n' | nc -U ~/Library/Application\ Support/ibattery-mcp/ble-helper.sock
```

Expected: a JSON array on stdout. With AirPods nearby and their lid opened during the 20s window, entries like `{"id":"ble-…-left","inCase":true,"kind":"airpods","name":"… (Left)",…}` appear; with nothing nearby, `[]` is acceptable. Also verify the old requests still work: `printf 'status\n' | nc -U ~/Library/Application\ Support/ibattery-mcp/ble-helper.sock` returns `{"authorized":…,"poweredOn":…}`.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint
git add Sources/IBatteryCore/DataSources/BLEAdvertisementMonitor.swift Sources/ibattery-ble-helper/main.swift
git commit -m "Add persistent advertisement monitor and snapshot IPC request to ble-helper"
```

---

### Task 5: MCP-side snapshot source and merge

**Files:**
- Modify: `Sources/IBatteryCore/DataSources/BLEBattery.swift` (add `fetchSnapshot` + `BLESnapshotSource`)
- Create: `Sources/IBatteryCore/DataSources/BLESnapshotMerge.swift`
- Modify: `Sources/IBatteryCore/DeviceRegistry.swift` (`getAllDevicesStatus` applies the merge)
- Modify: `Sources/ibattery-mcp/main.swift` (register `BLESnapshotSource`)
- Test: `Tests/IBatteryCoreTests/BLESnapshotMergeTests.swift`

**Interfaces:**
- Consumes: snapshot wire format and id convention (`"ble-"` prefix) from Tasks 3–4; `markStaleIfNeeded` (existing).
- Produces:
  - `BLEBatterySource.fetchSnapshot(readTimeoutSeconds: Int = 15) -> [DeviceBatteryInfo]` (static; 15s covers the helper's 10s GATT ceiling).
  - `struct BLESnapshotSource: BatteryDataSource`.
  - `let bleSnapshotIDPrefix = "ble-"`, `let bleAirPodsFreshnessWindow: TimeInterval = 600`.
  - `func mergeBLESnapshot(_ devices: [DeviceBatteryInfo], now: Date) -> [DeviceBatteryInfo]`.

Merge rules (from spec §4/§5/§6, resolved to code):
1. Any entry whose exact id was already emitted is dropped (absorbs old-helper skew, where `"snapshot"` returns generic-scan duplicates).
2. `.iosDevice` with `ble-` id: dropped when an official (non-`ble-`) `.iosDevice` with the same name exists; otherwise kept (stale-marked as needed). Official entries always pass through.
3. `.airpods` with `ble-` id, seen within 600s: emitted, but with the same-name profiler entry's MAC-based id when one exists (stable ids); the profiler duplicate is then skipped.
4. `.airpods` with `ble-` id, older than 600s: skipped when a same-name profiler entry exists (rule 5 carries the state over); kept as-is (stale-marked) when BLE is the only source that knows this device.
5. `.airpods` profiler entry whose same-name BLE entry is older than 600s: emitted with the profiler's percentage but `isCharging: nil`, the BLE entry's `inCase`/`lidOpen`, and the BLE entry's `lastUpdated` (the honest "when we last actually heard from the device" timestamp, per spec §4.2).
6. Everything else passes through unchanged.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IBatteryCoreTests/BLESnapshotMergeTests.swift`:

```swift
// Tests/IBatteryCoreTests/BLESnapshotMergeTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLESnapshotMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        id: String, name: String, kind: DeviceBatteryInfo.Kind,
        percentage: Int = 50, isCharging: Bool? = nil, age: TimeInterval = 0,
        inCase: Bool? = nil, lidOpen: Bool? = nil
    ) -> DeviceBatteryInfo {
        DeviceBatteryInfo(
            id: id, name: name, kind: kind, percentage: percentage,
            isCharging: isCharging, lastUpdated: now.addingTimeInterval(-age),
            inCase: inCase, lidOpen: lidOpen
        )
    }

    func testFreshBLEAirPods_winsOverProfiler_andKeepsProfilerID() {
        let merged = mergeBLESnapshot([
            entry(id: "aa:bb:cc:dd:ee:ff-left", name: "Pods (Left)", kind: .airpods, percentage: 90),
            entry(id: "ble-uuid1-left", name: "Pods (Left)", kind: .airpods, percentage: 85, isCharging: true, age: 30, inCase: true)
        ], now: now)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "aa:bb:cc:dd:ee:ff-left")
        XCTAssertEqual(merged[0].percentage, 85)
        XCTAssertEqual(merged[0].isCharging, true)
        XCTAssertEqual(merged[0].inCase, true)
        XCTAssertFalse(merged[0].stale)
    }

    func testStaleBLEAirPods_profilerLevelWithBLEInCaseAndHonestTimestamp() {
        let merged = mergeBLESnapshot([
            entry(id: "aa:bb:cc:dd:ee:ff-left", name: "Pods (Left)", kind: .airpods, percentage: 90, isCharging: nil),
            entry(id: "ble-uuid1-left", name: "Pods (Left)", kind: .airpods, percentage: 85, isCharging: true, age: 700, inCase: false)
        ], now: now)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "aa:bb:cc:dd:ee:ff-left")
        XCTAssertEqual(merged[0].percentage, 90)          // profiler level
        XCTAssertNil(merged[0].isCharging)                // spec §4.2
        XCTAssertEqual(merged[0].inCase, false)           // BLE last-known state
        XCTAssertEqual(merged[0].lastUpdated, now.addingTimeInterval(-700))
        XCTAssertTrue(merged[0].stale)                    // 700s > 120s threshold
    }

    func testFreshBLEOnlyAirPods_keptWithBLEID() {
        let merged = mergeBLESnapshot([
            entry(id: "ble-uuid1-case", name: "Pods (Case)", kind: .airpods, percentage: 70, age: 30, lidOpen: true)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "ble-uuid1-case")
        XCTAssertEqual(merged[0].lidOpen, true)
    }

    func testStaleBLEOnlyAirPods_keptAndMarkedStale() {
        let merged = mergeBLESnapshot([
            entry(id: "ble-uuid1-left", name: "Pods (Left)", kind: .airpods, age: 700)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].stale)
    }

    func testProfilerOnlyAirPods_passesThroughUnchanged() {
        let profiler = entry(id: "aa:bb:cc:dd:ee:ff-right", name: "Pods (Right)", kind: .airpods, percentage: 40)
        let merged = mergeBLESnapshot([profiler], now: now)
        XCTAssertEqual(merged, [profiler])
    }

    func testBLEIOSDevice_droppedWhenOfficialEntrySameName() {
        let merged = mergeBLESnapshot([
            entry(id: "00008150-FAKEUDID0001", name: "Test iPhone", kind: .iosDevice, percentage: 80, isCharging: false),
            entry(id: "ble-uuid2", name: "Test iPhone", kind: .iosDevice, percentage: 79)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "00008150-FAKEUDID0001")
    }

    func testBLEIOSDevice_keptWhenNoOfficialEntry() {
        let merged = mergeBLESnapshot([
            entry(id: "ble-uuid2", name: "Test iPhone", kind: .iosDevice, percentage: 79)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "ble-uuid2")
        XCTAssertEqual(merged[0].kind, .iosDevice)
    }

    func testDuplicateIDs_firstOccurrenceWins() {
        // Old-helper skew: "snapshot" answered by the generic-scan branch
        // duplicates entries BLEBatterySource already returned.
        let merged = mergeBLESnapshot([
            entry(id: "uuid3", name: "Test Mouse", kind: .bleGeneric, percentage: 60),
            entry(id: "uuid3", name: "Test Mouse", kind: .bleGeneric, percentage: 60)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
    }

    func testNonAirPodsNonIOSKinds_passThrough() {
        let mac = entry(id: "mac-internal", name: "MacBook Pro", kind: .mac, percentage: 95)
        let watch = entry(id: "watch-udid", name: "Watch7,2", kind: .watch, percentage: 88)
        let merged = mergeBLESnapshot([mac, watch], now: now)
        XCTAssertEqual(merged, [mac, watch])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BLESnapshotMergeTests 2>&1 | tail -10`
Expected: compile error — `cannot find 'mergeBLESnapshot' in scope`.

- [ ] **Step 3: Implement merge, snapshot fetch, source, and wiring**

Create `Sources/IBatteryCore/DataSources/BLESnapshotMerge.swift`:

```swift
// Sources/IBatteryCore/DataSources/BLESnapshotMerge.swift
//
// Pure post-pass over DeviceRegistry results reconciling ble-helper
// snapshot entries (id prefix "ble-") with the official sources, per the
// merge rules in docs/superpowers/specs/2026-07-20-ble-advertisement-design.md
// §4–§6. Origin is determined entirely by the id prefix, so the pass is
// independent of source ordering.
import Foundation

/// Marks entries that came from the ble-helper's advertisement snapshot
/// rather than an official path.
public let bleSnapshotIDPrefix = "ble-"

/// How recently a BLE advertisement must have been seen for its battery
/// level to be preferred over system_profiler's cached value (spec §4).
public let bleAirPodsFreshnessWindow: TimeInterval = 600

public func mergeBLESnapshot(_ devices: [DeviceBatteryInfo], now: Date) -> [DeviceBatteryInfo] {
    let bleAirPodsByName = Dictionary(
        devices
            .filter { $0.kind == .airpods && $0.id.hasPrefix(bleSnapshotIDPrefix) }
            .map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let profilerAirPodsIDByName = Dictionary(
        devices
            .filter { $0.kind == .airpods && !$0.id.hasPrefix(bleSnapshotIDPrefix) }
            .map { ($0.name, $0.id) },
        uniquingKeysWith: { first, _ in first }
    )
    let officialIOSNames = Set(
        devices
            .filter { $0.kind == .iosDevice && !$0.id.hasPrefix(bleSnapshotIDPrefix) }
            .map(\.name)
    )

    var merged: [DeviceBatteryInfo] = []
    var seenIDs = Set<String>()

    func emit(_ device: DeviceBatteryInfo) {
        guard !seenIDs.contains(device.id) else { return }
        seenIDs.insert(device.id)
        merged.append(device)
    }

    for device in devices {
        let isBLE = device.id.hasPrefix(bleSnapshotIDPrefix)
        switch device.kind {
        case .iosDevice where isBLE:
            // Official libimobiledevice entry wins by name; the BLE-GATT
            // entry only fills the gap (the locked-phone case).
            guard !officialIOSNames.contains(device.name) else { continue }
            emit(markStaleIfNeeded(device, now: now))

        case .airpods where isBLE:
            let fresh = now.timeIntervalSince(device.lastUpdated) <= bleAirPodsFreshnessWindow
            if fresh {
                // Fresh advertisement data wins, but keeps the profiler's
                // stable MAC-based id when one exists.
                let id = profilerAirPodsIDByName[device.name] ?? device.id
                emit(markStaleIfNeeded(DeviceBatteryInfo(
                    id: id,
                    name: device.name,
                    kind: .airpods,
                    percentage: device.percentage,
                    isCharging: device.isCharging,
                    lastUpdated: device.lastUpdated,
                    inCase: device.inCase,
                    lidOpen: device.lidOpen
                ), now: now))
            } else if profilerAirPodsIDByName[device.name] == nil {
                // Stale, but BLE is the only source that knows this device —
                // an honest stale entry beats losing it entirely.
                emit(markStaleIfNeeded(device, now: now))
            }
            // Stale with a profiler entry present: skipped — the profiler
            // branch below carries the state over.

        case .airpods where !isBLE:
            if let ble = bleAirPodsByName[device.name] {
                let bleFresh = now.timeIntervalSince(ble.lastUpdated) <= bleAirPodsFreshnessWindow
                if bleFresh {
                    continue // the fresh BLE entry already claimed this name (and this id)
                }
                // Profiler's cached level, but the monitor's last-known
                // in-case state with its honest last-seen timestamp
                // (spec §4.2). isCharging: nil — the profiler doesn't know
                // it and the BLE data is too old to assert it.
                emit(markStaleIfNeeded(DeviceBatteryInfo(
                    id: device.id,
                    name: device.name,
                    kind: .airpods,
                    percentage: device.percentage,
                    isCharging: nil,
                    lastUpdated: ble.lastUpdated,
                    inCase: ble.inCase,
                    lidOpen: ble.lidOpen
                ), now: now))
            } else {
                emit(device)
            }

        default:
            emit(device)
        }
    }
    return merged
}
```

In `Sources/IBatteryCore/DataSources/BLEBattery.swift`, add inside `BLEBatterySource` (after `fetchBluetoothStatus`):

```swift
    /// Fetches the helper's advertisement snapshot: cached AirPods state
    /// plus GATT battery reads of nearby iOS devices. The default timeout
    /// covers the helper's 10s GATT ceiling with headroom. Returns [] when
    /// the helper is unreachable — callers degrade to the official paths.
    public static func fetchSnapshot(readTimeoutSeconds: Int = 15) -> [DeviceBatteryInfo] {
        guard let socketFD = connectToHelper(readTimeoutSeconds: readTimeoutSeconds) else { return [] }
        defer { close(socketFD) }
        let responseData = sendRequestAndReadResponse(socketFD: socketFD, request: "snapshot\n")
        return parseHelperResponse(responseData)
    }
```

And add at the end of the same file:

```swift
/// Registry source for the helper's advertisement snapshot. Emits raw
/// snapshot entries (ids prefixed "ble-"); DeviceRegistry's
/// mergeBLESnapshot pass reconciles them with the official sources.
public struct BLESnapshotSource: BatteryDataSource {
    public init() {}

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: BLEBatterySource.fetchSnapshot())
            }
        }
    }
}
```

In `Sources/IBatteryCore/DeviceRegistry.swift`, replace the body of `getAllDevicesStatus` with:

```swift
    public func getAllDevicesStatus() async -> [DeviceBatteryInfo] {
        var results: [DeviceBatteryInfo] = []
        for source in sources {
            results.append(contentsOf: await source.fetchAll())
        }
        let merged = mergeBLESnapshot(results, now: Date())
        for device in merged {
            cache[device.id] = device
        }
        return merged
    }
```

In `Sources/ibattery-mcp/main.swift`, extend the source list:

```swift
let registry = DeviceRegistry(sources: [
    MacBatterySource(),
    BLEBatterySource(),
    IDeviceBatterySource(),
    WatchBatterySource(),
    AirPodsBatterySource(),
    BLESnapshotSource()
])
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass, including the new BLESnapshotMergeTests and every pre-existing suite.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint
git add Sources/IBatteryCore/DataSources/BLESnapshotMerge.swift Sources/IBatteryCore/DataSources/BLEBattery.swift Sources/IBatteryCore/DeviceRegistry.swift Sources/ibattery-mcp/main.swift Tests/IBatteryCoreTests/BLESnapshotMergeTests.swift
git commit -m "Merge ble-helper snapshot entries into registry results"
```

---

### Task 6: Documentation, tool description, end-to-end verification

**Files:**
- Modify: `Sources/IBatteryCore/MCPServerFactory.swift` (tool description)
- Modify: `README.md`, `README_zh.md`, `CHANGELOG.md`

**Interfaces:** none new.

- [ ] **Step 1: Update the `get_all_devices_status` tool description**

In `Sources/IBatteryCore/MCPServerFactory.swift`, replace the description string of `get_all_devices_status` with:

```swift
            description: """
            Get battery and charging status for all Apple devices discoverable from this Mac: \
            this Mac's own battery, nearby Bluetooth devices exposing standard battery reporting, \
            a paired iPhone/iPad (over USB/WiFi sync, or — even while locked — via a Bluetooth \
            battery read), an Apple Watch reachable through that iPhone, and AirPods (or other \
            Apple-vendor earbuds) known to this Mac's Bluetooth stack, including per-bud \
            in-case status and charging state when they're nearby and broadcasting.
            """,
```

- [ ] **Step 2: Update README.md**

In the Status table, replace the AirPods row and the iPhone/iPad row with:

```markdown
| iPhone / iPad | ✅ Verified over USB/WiFi · ⚠️ locked-phone Bluetooth path implemented, not yet hardware-verified |
| AirPods | ⚠️ Real-time levels, charging and per-bud in-case status via BLE advertisements (with `system_profiler` fallback) — implemented, unit-tested, not yet confirmed against real hardware |
```

In the "Why a separate helper app for Bluetooth?" section, append to the end of the paragraph:

```markdown
Besides on-demand scans, the helper also passively listens for BLE
advertisements in the background (15s at launch, then 5s every 30s): AirPods
broadcast their battery, charging and in-case state in plaintext while in
use, and stop shortly after their lid closes — continuous listening is what
catches the lid-close message carrying the exact per-bud in-case state. The
same listener spots nearby iOS devices so their battery can be read over
standard Bluetooth GATT even while they're locked and unreachable via WiFi
sync.
```

Mirror both changes in `README_zh.md` (translated).

- [ ] **Step 3: Update CHANGELOG.md**

Add under the Unreleased/current section (match the file's existing format):

```markdown
- AirPods: real-time battery, charging state, and per-bud in-case status
  (`inCase`, `lidOpen` fields) parsed from plaintext BLE advertisements,
  with `system_profiler` as fallback — per the amended engineering
  principle (see docs/superpowers/specs/2026-07-20-ble-advertisement-design.md).
- iPhone/iPad: battery readable while the phone is locked, via a standard
  Bluetooth GATT Battery Service read of devices spotted by the helper's
  new passive advertisement listener.
- ibattery-ble-helper: new persistent advertisement monitor and "snapshot"
  IPC request (existing "scan"/"status" requests unchanged).
```

- [ ] **Step 4: Full verification**

```bash
swiftlint
swift test 2>&1 | tail -3
./Scripts/build-ble-helper-app.sh
pkill -x ibattery-ble-helper || true
open .build/ibattery-ble-helper.app
```

Then the end-to-end MCP check (open the AirPods lid near the Mac first, wait ~30s for a scan window to catch it):

```bash
BIN=.build/arm64-apple-macosx/debug/ibattery-mcp
{ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_all_devices_status","arguments":{}}}'
  sleep 20; } | "$BIN"
```

Expected: AirPods entries carry `"inCase"`/`"lidOpen"` keys and a real `"isCharging"` value; with the iPhone locked (give the phone ~1 min after locking, then rerun), an iPhone entry with a `"ble-"`-prefixed id may appear — if it doesn't, that's the known unverified-hardware caveat, not a task failure; README wording already reflects it.

- [ ] **Step 5: Commit**

```bash
git add Sources/IBatteryCore/MCPServerFactory.swift README.md README_zh.md CHANGELOG.md
git commit -m "Document BLE advertisement features in README/CHANGELOG and tool description"
```

---

## Self-Review Notes (already applied)

- Spec coverage: §2 architecture → Tasks 3–5; §3 parsing + confidence table → Task 2; §4 fields/merge → Tasks 1, 5; §5 iPhone over BT → Tasks 4–5; §6 error handling → guard-and-degrade paths in Tasks 4–5 (old-helper skew covered by `testDuplicateIDs_firstOccurrenceWins` and the ios/airpods filters); §7 testing → each task's test steps; §8 CLAUDE.md → already committed during design; §9 docs → Task 6; §10 out-of-scope respected (no model-ID parsing, no 2A29 vendor read, no in-ear detection — deviations noted in Task 4 preamble).
- Type consistency: `AirPodsComponentState`/`AirPodsAdvertisementState` field names identical across Tasks 2–3; snapshot id convention `ble-<uuid>-<component>` identical across Tasks 3, 4, 5; `fetchSnapshot` signature identical in Tasks 4 (wire) and 5 (client).
- The spec's §4.3 "BLE-only devices fall back to CoreBluetooth peripheral UUID" is implemented as the `ble-<uuid>` id passing through the merge unchanged when no profiler entry exists.
