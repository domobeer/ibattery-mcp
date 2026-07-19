# ibattery-mcp Design Doc

Date: 2026-07-19
Status: Approved (brainstorming phase)

## 1. Overview

**ibattery-mcp** is an open-source MCP (Model Context Protocol) server that exposes
battery/status information for a user's Apple devices (Mac, iPhone, iPad, Apple
Watch, AirPods, and other Bluetooth peripherals) as MCP tools, so an AI assistant
(Claude Code, Claude Desktop, or an agent runtime like Work Buddy) can answer
questions like "how much battery does my AirPods have left?" or generate a
consolidated status report.

**Primary motivating use case:** integration with
[Work Buddy](https://docs.work-buddy.ai/) (a local-first personal-agent runtime
built on Claude Code), specifically its scheduled morning-briefing workflow
(`/wb-morning`). ibattery-mcp supplies the "all my Apple devices' battery/status"
section of that briefing.

**Relationship to AirBattery:** [AirBattery](https://github.com/lihaoyun6/AirBattery)
(GNU AGPLv3) is the closest prior art — a macOS menu-bar app that surfaces the same
kind of data. ibattery-mcp is an **independent, clean-room reimplementation**: no
code, assets, or bundled binaries from AirBattery are reused. Device-communication
protocols that are public knowledge (e.g. Apple's Continuity BLE broadcast format,
documented independently by multiple community reverse-engineering efforts) may
inform the implementation, but all parsing/handling code is written from scratch.
This is a deliberate choice so the project can ship under a permissive license
(see §7) instead of inheriting AGPLv3's copyleft/network-source-disclosure
obligations.

## 2. Architecture

- **Single native Swift binary.** All device I/O requires deep macOS system
  frameworks (CoreBluetooth, IOBluetooth, IOKit, log subsystem access), so the
  MCP protocol layer and the data-gathering logic live in the same process/language
  — no cross-language boundary, no shelling out between a scripting layer and a
  compiled helper.
- **MCP protocol layer:** official
  [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk),
  **stdio transport**.
- **Stateless / on-demand, except for anything touching CoreBluetooth.** The
  MCP process is spawned by the MCP host (Claude Code / Work Buddy's gateway)
  only when a tool is invoked, and exits when the host disconnects. This holds
  for:
  - Local Mac battery: instant IOKit query, no wait.
  - Bluetooth-log-scraped battery data: query the last few minutes of the system
    log at call time rather than tailing it continuously.
  - iPhone/iPad/Watch: direct request/response at call time.

  **BLE peripherals are the one exception, and require a persistent helper
  app — this was not the original plan and was discovered empirically during
  Plan 1 implementation.** macOS attributes CoreBluetooth's privacy (TCC)
  check to the *responsible process*, not to whichever binary happens to call
  the API. A bare executable spawned as a stdio subprocess (which is exactly
  what an MCP server is, by construction — forked/exec'd directly by its host,
  never launched via `open`/LaunchServices) inherits its TCC responsibility
  from its parent (Claude Code / Work Buddy), which has no
  `NSBluetoothAlwaysUsageDescription` of its own. The result is a hard
  `SIGABRT` the instant `CBCentralManager` is instantiated — not a catchable
  Swift error, not a graceful `.denied` authorization state — regardless of
  what the MCP binary's own `Info.plist`/code-signing/entitlements say.
  Confirmed empirically: embedding an `Info.plist` via linker section, ad-hoc
  signing, and wrapping the binary in a real `.app` bundle all still crash
  when the binary is exec'd directly; only launching via `open` (real
  LaunchServices) avoids it. AirBattery itself only works because it *is* the
  top-level, user-launched `.app` — its own `AirBattery.entitlements` is
  empty; the only thing it declares is
  `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`, and that's sufficient
  *because AirBattery is the responsible process*, which an MCP subprocess can
  never be.

  **Resolution:** introduce `ibattery-ble-helper`, a small persistent helper
  app (a real `.app` bundle, the same shape as AirBattery itself) that owns
  all CoreBluetooth access. It is launched once (manually, or registered as a
  login item via `SMAppService` on first run) and stays running, listening on
  a local Unix domain socket for scan requests. The stateless MCP process's
  `BLEBatterySource` becomes a thin IPC client: connect to the socket, request
  a scan, parse the JSON response, with a short timeout. If the socket isn't
  reachable (helper not installed/running), it returns an empty result plus a
  warning telling the user to launch the helper — this replaces the
  originally-planned `CBManager.authorization` check (§5), since the MCP
  process itself never touches CoreBluetooth anymore and so never needs to
  ask its own authorization state.

  This unifies with the "LAN multi-Mac" companion below — both need a
  persistent, `open`-launched process, so `ibattery-ble-helper` and the LAN
  companion are the same component, not two.
- **Distribution:** Homebrew tap (`brew install <org>/tap/ibattery-mcp`) as the
  primary path, with the formula **building from source** on the user's
  machine (the standard pattern for most open-source CLI formulas) — this
  avoids any dependency on an Apple Developer ID / notarization pipeline.
  Source tarballs are also attached to tagged GitHub Releases for anyone
  installing outside Homebrew.

## 3. Device Data Sources (v1 scope)

| Device type | Method | Notes |
|---|---|---|
| Mac (this machine) | IOKit `AppleSmartBattery` | Straightforward, high reliability |
| AirPods / Beats (BLE) | `ibattery-ble-helper` scans + parses Apple Continuity manufacturer-data broadcasts, MCP process queries it over a local socket | Clean-room parser; byte-offset table derived from public reverse-engineering knowledge, not copied from AirBattery. Runs inside the persistent helper app, not the stateless MCP process (see §2). |
| Magic Mouse/Keyboard/Trackpad, generic BT HID | IOBluetooth registry + `system_profiler SPBluetoothDataType -json` | Uses stock system CLI, no bundled binaries. Does not touch `CBCentralManager`, so — unlike the two BLE rows above — this one is *not* subject to the responsible-process/TCC constraint and can stay in the stateless MCP process. |
| Generic BLE devices exposing standard GATT Battery Service (`180F`/`2A19`) | `ibattery-ble-helper` scans via CoreBluetooth, MCP process queries it over a local socket | Works for any spec-compliant peripheral. Same helper-app requirement as the AirPods row, for the same reason. |
| iPhone / iPad (USB or WiFi) | Shell out to `libimobiledevice` CLI tools (`idevice_id`, `ideviceinfo`) | **Declared as a Homebrew formula dependency**, not bundled — cleaner supply chain than vendoring prebuilt binaries. libimobiledevice is LGPL and is an independent upstream project; depending on it is unrelated to AirBattery's licensing. |
| Apple Watch (via paired iPhone) | Companion-proxy protocol over lockdownd | **Flagged as a research spike** — protocol needs to be independently investigated; if it proves too costly to implement cleanly for v1, ship v1 without Watch support and add it in a point release rather than block launch. |

### `ibattery-ble-helper`: now required for v1's BLE rows, and doubles as the optional LAN multi-Mac companion

Originally scoped as purely optional (see below), but §2's TCC finding makes a
persistent, `open`-launched helper **required for v1**, just to make the
AirPods/generic-BLE rows above functional at all — not just for cross-Mac
lookup. One component now serves both purposes:
- **Required for v1:** owns all `CBCentralManager` access (AirPods Continuity
  parsing, generic BLE Battery Service scanning), exposed to the stateless MCP
  process over a local Unix domain socket.
- **Optional add-on (unchanged from the original plan):** the same running
  helper can also act as a LAN multi-Mac companion — confirmed wanted (the
  user owns multiple Macs) — answering queries from other Macs' helpers over
  Bonjour/`NWListener`, so a query can also return devices seen by *other*
  Macs' helpers, not just this one. This half remains opt-in (a separate
  enable step, not on by default) and ships after core v1; the local-BLE half
  above does not, since without it the BLE rows in the table above simply
  don't work.
- Packaging: a real `.app` bundle (not a bare SwiftPM executable) with its own
  `Info.plist` declaring `NSBluetoothAlwaysUsageDescription`, following
  AirBattery's own proof that no special entitlements are needed beyond that
  — registered as a login item via `SMAppService` on first manual launch, the
  same pattern AirBattery's own `AirBatteryHelper` target uses for its login
  item (though AirBattery's helper itself does no Bluetooth work — that
  precedent is about login-item registration, not TCC).
- Local IPC: Unix domain socket, simple newline-delimited JSON request/response
  (exact protocol detailed in the implementation plan for this component).
- Peer discovery for the LAN half: Bonjour/`NWListener` service type
  advertisement; simple authenticated request/response protocol (shared-secret
  or local pairing token — exact scheme to be detailed in its own follow-up
  plan, unchanged from the original design).

## 4. MCP Tool Surface

- `get_all_devices_status()` — returns battery/status for every device
  discoverable from this Mac in one call. Primary tool for the morning-briefing
  use case.
- `get_device_battery(name_or_type)` — query a single device by name or type
  (e.g. "AirPods Pro", "iPhone"). Primary tool for interactive/conversational use.
- `list_known_devices()` — lists recently-seen devices with type and
  last-updated timestamp, without forcing a fresh scan of everything.

Exact JSON schemas for tool inputs/outputs will be finalized in the
implementation plan.

## 5. Error Handling

- **`ibattery-ble-helper` not reachable** (not installed, not running, or its
  own Bluetooth permission not yet granted): the MCP process's `BLEBatterySource`
  never touches CoreBluetooth itself (see §2), so this surfaces as a socket
  connection failure, not a crash. Return an actionable message directing the
  user to launch the helper app (and, if the helper reports its own
  `.denied`/`.restricted` Bluetooth authorization, relay that as guidance to
  grant access in System Settings) — never a raw connection-refused error.
- **Stale data:** if a device hasn't reported within a threshold window, mark
  it with `stale: true` in the response instead of omitting it (mirrors
  AirBattery's ⚠️ convention, reimplemented independently).
- **iPhone/iPad not trusted / `libimobiledevice` missing:** detect and surface
  a specific remediation message ("trust this computer on your iPhone" /
  "brew install libimobiledevice").
- **Apple Watch relay failure** (paired iPhone unreachable, etc.): degrade
  gracefully — return results for all other devices plus a per-device failure
  reason for the Watch, never fail the whole call.

## 6. Testing Strategy

- **Unit-testable logic** (BLE advertisement parsing, JSON encoding/decoding,
  protocol framing) gets real unit tests using synthetic byte fixtures, run in
  GitHub Actions on macOS runners.
- **Hardware-dependent behavior** (live AirPods, live iPhone pairing) cannot be
  exercised in CI. This limitation is documented explicitly in
  `CONTRIBUTING.md`, with a manual QA checklist required before tagging a
  release.

## 7. Licensing

- **MIT license** for the whole project (clean-room code, no AGPL inheritance
  from AirBattery).
- Third-party dependency notices (e.g. libimobiledevice's own LGPL license,
  Swift MCP SDK's license) documented in a `THIRD_PARTY_NOTICES` file /
  README acknowledgments section, consistent with standard OSS practice —
  distinct from AirBattery's own "Thanks" section, since we are not bundling
  their binaries.

## 8. Open-Source Project Hygiene

- `LICENSE` (MIT), `README.md` (English, default) and `README_zh.md` (Chinese)
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`
- GitHub issue templates (bug report / feature request) and PR template
- GitHub Actions: CI (build + unit tests + lint) on PRs; release automation
  (tag → publish source tarball as a GitHub Release → update Homebrew tap
  formula's version/checksum)
- GitHub Pages landing page (visually polished, EN default / ZH toggle) — visual
  design to be scoped separately in the implementation plan, not part of this
  architecture doc.

## 9. Repository

- New standalone repo at `/Users/drummond/Documents/workspace/ibattery-mcp`,
  project and package name **`ibattery-mcp`** throughout (binary name, Homebrew
  formula name, repo name).

## 10. Known Risks / Open Items for Implementation Planning

- Apple Watch companion-proxy protocol: needs a research spike before scope is
  finalized; may slip to a point release.
- LAN multi-Mac half of `ibattery-ble-helper`: authentication scheme and
  peer-discovery details need to be designed in their own follow-up spec
  before implementation (unchanged from the original plan — only the local-BLE
  half of the helper is required for v1).
- **Resolved during Plan 1 implementation:** BLE scanning cannot run inside the
  stateless MCP process at all (macOS TCC responsible-process attribution —
  see §2); this was discovered empirically via a real SIGABRT crash when Task
  5 first wired `BLEBatterySource` into a running server, not anticipated
  during original brainstorming. Resolved by introducing `ibattery-ble-helper`
  as a required v1 component rather than treating BLE as fully stateless.
- `ibattery-ble-helper` packaging is new work not covered by Plan 1's original
  task breakdown: needs its own implementation plan (target setup, `.app`
  bundle assembly from a SwiftPM-built binary, Unix socket protocol, login-item
  registration, first-run UX for when the helper isn't installed/running yet).
