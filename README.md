# ibattery-mcp

[![CI](https://github.com/China-Drummond/ibattery-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/China-Drummond/ibattery-mcp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/China-Drummond/ibattery-mcp)](https://github.com/China-Drummond/ibattery-mcp/releases)

An [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server that
exposes battery and charging status for your Apple devices — this Mac, nearby
Bluetooth accessories, your iPhone/iPad, and your Apple Watch — as tools an AI
assistant (Claude Code, Claude Desktop, [Work Buddy](https://docs.work-buddy.ai/),
or any other MCP client) can call.

[中文版本](./README_zh.md)

## Status

| Device | Status |
|---|---|
| This Mac's own battery | ⚠️ Implemented, unit-tested — not yet confirmed against real hardware |
| Generic Bluetooth devices (standard Battery Service — most Bluetooth mice/keyboards) | ⚠️ Implemented, unit-tested — real BLE scanning works, but no compatible peripheral confirmed yet |
| iPhone / iPad | ✅ Verified over USB/WiFi · ⚠️ locked-phone Bluetooth path implemented, not yet hardware-verified |
| Apple Watch (via a paired iPhone) | ✅ Verified against real hardware |
| AirPods | ⚠️ Real-time levels, charging and per-bud in-case status via BLE advertisements (with `system_profiler` fallback) — implemented, unit-tested, not yet confirmed against real hardware |
| Another Mac on the same network | ❌ Not planned — see [Why not another Mac?](#why-not-another-mac) below |

This project is pre-1.0 and under active development. See
[CHANGELOG.md](./CHANGELOG.md) for details.

## Why a separate helper app for Bluetooth?

macOS attributes CoreBluetooth's privacy (TCC) check to the *responsible
process*, not to whichever binary actually calls the API. An MCP server is,
by construction, a subprocess spawned directly by its host (Claude Code,
Claude Desktop, etc.) — never launched via macOS LaunchServices (`open`). That
means a bare MCP server can never itself be its own "responsible process" for
Bluetooth access, and will be killed by the OS the instant it tries. `ibattery-mcp`
works around this the same way a normal Mac app would: a small companion app,
`ibattery-ble-helper`, owns all Bluetooth access and is launched normally
(`open`, or as a login item); the stateless MCP server talks to it over a
local Unix domain socket. See the [design doc](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)
for the full story, including how this was discovered.

Besides on-demand scans, the helper also passively listens for BLE
advertisements in the background (15s at launch, then 5s every 30s): AirPods
broadcast their battery, charging and in-case state in plaintext while in
use, and stop shortly after their lid closes — continuous listening is what
catches the lid-close message carrying the exact per-bud in-case state. The
same listener spots nearby iOS devices so their battery can be read over
standard Bluetooth GATT even while they're locked and unreachable via WiFi
sync.

## Why not another Mac?

Unlike iPhone/iPad, Apple Watch, and AirPods — where macOS or iOS already
silently collects and syncs the battery data somewhere (lockdownd's
pairing relationship, iCloud key-sharing feeding this Mac's own Bluetooth
stack) and this project just reads it — there's no equivalent built-in
channel for another Mac's battery. Find My can show it, but only via a
closed, cloud-based path with no local or scriptable access. Seeing
another Mac's status genuinely requires a custom peer-to-peer app running
on *every* Mac involved, likely gated behind macOS's Local Network
permission the same way Bluetooth is gated behind its own responsible-
process rule — a second persistent helper, its own discovery/auth design,
with no official API to lean on. Weighed against that cost during design,
this was deliberately not pursued. See the
[design doc](./docs/superpowers/specs/2026-07-20-lan-multi-mac-design.md)
for the full reasoning.

## Installation

### Prerequisites

- macOS 13 (Ventura) or later
- [Homebrew](https://brew.sh)

### Install

```bash
brew install China-Drummond/tap/ibattery-mcp
```

This also installs `libimobiledevice` and `pkg-config` as dependencies
(needed for iPhone/iPad/Apple Watch support) and builds `ibattery-mcp` from
source on your machine.

### One-time setup for Bluetooth device support

Bluetooth devices (generic BLE accessories) require the companion helper app
to be running:

```bash
open "$(brew --prefix ibattery-mcp)/libexec/ibattery-ble-helper.app"
```

The first launch will prompt for Bluetooth permission — grant it. The helper
app then keeps running in the background; you only need to do this once (or
again after a reboot, unless you set it up as a login item).

### One-time setup for iPhone/iPad/Apple Watch support

Connect your iPhone or iPad to this Mac via USB at least once and tap "Trust"
when prompted. This establishes the pairing libimobiledevice needs; after
that, it can also work over WiFi if you have WiFi sync enabled on the device.

## Configuration

Add `ibattery-mcp` to your MCP host's configuration. For example, for a host
that reads a JSON config with a `command`/`args` shape:

```json
{
  "mcpServers": {
    "ibattery-mcp": {
      "command": "ibattery-mcp"
    }
  }
}
```

## Available tools

- **`get_all_devices_status()`** — battery/status for every device discoverable
  from this Mac right now. The main tool for a "how are my devices doing"
  summary (e.g., a morning briefing).
- **`get_device_battery(query)`** — battery status for one device matching a
  name or type substring (e.g. `"iPhone"`, `"MacBook"`).
- **`list_known_devices()`** — devices seen so far this session, without
  triggering a fresh scan.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for how to set up a development
environment, run the test suite, and submit changes.

## License

[MIT](./LICENSE)

## Acknowledgments

- [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) —
  the official Swift SDK this project's MCP protocol layer is built on.
- [libimobiledevice](https://libimobiledevice.org) — the open-source library
  this project uses (as an external dependency, not bundled) for iPhone/iPad
  and Apple Watch communication.
- [AirBattery](https://github.com/lihaoyun6/AirBattery) — prior art that
  inspired this project. `ibattery-mcp` is an independent, clean-room
  reimplementation (see the [design doc](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)
  for why) and shares no code with it.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=China-Drummond/ibattery-mcp&type=Date)](https://star-history.com/#China-Drummond/ibattery-mcp&Date)
