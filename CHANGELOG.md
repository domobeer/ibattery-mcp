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
- iPhone/iPad battery via `libimobiledevice` CLI tools. **Implemented and
  unit-tested, but not yet verified against real hardware** — see the project
  README's Status section.
- Apple Watch battery via `libimobiledevice`'s `companion_proxy` API, reached
  through an already-connected iPhone. **Implemented and unit-tested, but not
  yet verified against real hardware** — see the project README's Status
  section.

### Known limitations
- AirPods (and Apple's proprietary Continuity BLE protocol generally) are not
  yet supported — planned for a future release once independently verified
  against real hardware.
- Querying another Mac's devices over the local network (LAN multi-Mac) is not
  yet implemented.