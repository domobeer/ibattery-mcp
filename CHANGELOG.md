# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- MCP server (`ibattery-mcp`) exposing three tools: `get_all_devices_status`,
  `get_device_battery`, `list_known_devices`.
- Mac's own battery via IOKit. **Implemented and unit-tested, but not yet
  verified against real hardware** — see the project README's Status section.
- Generic Bluetooth devices exposing the standard GATT Battery Service, via a
  separate persistent helper app (`ibattery-ble-helper`) that owns all
  CoreBluetooth access (required due to macOS TCC responsible-process rules —
  see the design doc for why a plain MCP subprocess can't touch CoreBluetooth
  directly). **Implemented and unit-tested, but not yet verified against real
  hardware** — see the project README's Status section.
- iPhone/iPad battery via `libimobiledevice` CLI tools. **Verified against a
  real device.**
- Apple Watch battery via `libimobiledevice`'s `companion_proxy` API, reached
  through an already-connected iPhone. **Verified against real hardware.**
- AirPods (and other Apple-vendor truly-wireless earbuds with a case)
  battery via `system_profiler SPBluetoothDataType -json` — reports Left,
  Right, and Case battery as separate entries; works even when the AirPods
  are connected to a different device on the same iCloud account, not just
  this Mac. **Implemented, unit-tested, not yet verified against real
  hardware** — see the project README's Status section.
- `lastUpdatedLocal`: every device entry's JSON now also includes an
  ISO8601 timestamp in this Mac's local UTC offset, alongside the existing
  UTC `lastUpdated`, so a caller doesn't need to separately know the user's
  timezone to reason about how fresh a reading is.
- AirPods: real-time battery, charging state, and per-bud in-case status
  (`inCase`, `lidOpen` fields) parsed from plaintext BLE advertisements,
  with `system_profiler` as fallback — per the amended engineering
  principle (see docs/superpowers/specs/2026-07-20-ble-advertisement-design.md).
- iPhone/iPad: battery readable while the phone is locked, via a standard
  Bluetooth GATT Battery Service read of devices spotted by the helper's
  new passive advertisement listener.
- ibattery-ble-helper: new persistent advertisement monitor and "snapshot"
  IPC request (existing "scan"/"status" requests unchanged).

### Fixed
- Apple Watch battery reading failed against real hardware in two ways: (1)
  a `companion_proxy` client was reused across requests, but the service
  closes its connection after every reply, so the second and later requests
  failed with `COMPANION_PROXY_E_SSL_ERROR`; (2)
  `companion_proxy_get_value_from_registry` returns the requested value
  wrapped in a one-entry dict keyed by the request key, not as a bare scalar,
  so the capacity value was silently misread as 0. Both are fixed.

### Known limitations
- Querying another Mac's devices over the local network (LAN multi-Mac) is
  **not planned**. Unlike every other source in this project, there's no
  existing macOS/iCloud channel that already syncs this data — it would
  require a second custom peer-to-peer helper app running on every Mac
  involved, most likely gated behind the same kind of Local Network
  permission wall Bluetooth already needed a helper for, with no official
  API to lean on. Weighed against that cost during design and deliberately
  not pursued — see the
  [design doc](./docs/superpowers/specs/2026-07-20-lan-multi-mac-design.md).