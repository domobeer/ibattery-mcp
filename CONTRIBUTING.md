# Contributing to ibattery-mcp

Thanks for considering a contribution! This project is under active
development — see [CHANGELOG.md](./CHANGELOG.md) for current status and
[README.md](./README.md) for what's implemented vs. planned.

## Development setup

You'll need:

- macOS 13+ with **full Xcode installed** (not just Command Line Tools — the
  test suite needs the full `XCTest` framework, which Command-Line-Tools-only
  installs don't provide). Check with `xcrun --find xctest`; if that errors,
  install Xcode from the App Store.
- [Homebrew](https://brew.sh)
- Build/runtime dependencies:
  ```bash
  brew install libimobiledevice pkg-config
  ```

Clone the repo and build:

```bash
git clone https://github.com/China-Drummond/ibattery-mcp.git
cd ibattery-mcp
swift build
swift test
```

## Project structure

- `Sources/IBatteryCore/` — the shared library: device models, all
  `BatteryDataSource` implementations (`MacBatterySource`, `BLEBatterySource`,
  `IDeviceBatterySource`, `WatchBatterySource`), the `DeviceRegistry`
  aggregator, and the MCP tool-handling code.
- `Sources/ibattery-mcp/` — the thin MCP server executable entry point.
- `Sources/ibattery-ble-helper/` — the separate helper app that owns all
  CoreBluetooth access (see the README's "Why a separate helper app" section
  for why this exists as its own process).
- `Sources/CLibimobiledevice/` — a SwiftPM system-library target exposing
  libimobiledevice's C headers to Swift.
- `Tests/IBatteryCoreTests/` — the test suite.
- `docs/superpowers/specs/` — the design doc.
- `docs/superpowers/plans/` — implementation plans, one per feature area, each
  written *before* the corresponding code and kept as a historical record of
  what was built and why (including empirically-verified facts discovered
  along the way — these are worth reading before touching a given subsystem).

## Testing philosophy

Pure logic (parsing functions, warning-message construction, cache/registry
behavior) is unit tested with synthetic fixtures and runs in CI. Code that
does real I/O against hardware or external processes (Bluetooth scanning,
`idevice_id`/`ideviceinfo` subprocess calls, the `companion_proxy` API) is
**not** unit tested — it can't be, without the real hardware attached — and is
manual-QA-only. If you're changing one of the `BatteryDataSource`
implementations, please note in your PR description what manual testing you
did (and on what hardware), since CI can't verify that part for you.

## Submitting changes

1. Open an issue first for anything beyond a small fix, so we can discuss
   the approach before you put in the work.
2. Keep PRs focused — one logical change per PR.
3. Add tests for any new pure-logic code; note manual hardware testing for
   anything that touches real devices.
4. Make sure `swift test` and `swiftlint` (see `.swiftlint.yml`) both pass
   locally before opening a PR — CI will run both.
5. Follow the existing code style (no forced abbreviations, `guard`-based
   early returns, `defer`-based cleanup for any C resource handles).
