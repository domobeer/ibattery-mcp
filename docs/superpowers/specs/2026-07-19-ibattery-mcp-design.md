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
- **Stateless / on-demand.** The process is spawned by the MCP host (Claude Code /
  Work Buddy's gateway) only when a tool is invoked, and exits when the host
  disconnects. There is no persistent background daemon, no LaunchAgent, no login
  item required for the core (single-Mac) feature set. This matches Work Buddy's
  own model: it runs locally on top of Claude Code and spawns local MCP servers
  on demand, so a remote-accessible/always-on server is unnecessary.
  - Local Mac battery: instant IOKit query, no wait.
  - BLE peripherals: active scan window of ~3-5s per call to catch periodic
    advertisement broadcasts.
  - Bluetooth-log-scraped battery data: query the last few minutes of the system
    log at call time rather than tailing it continuously.
  - iPhone/iPad/Watch: direct request/response at call time.
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
| AirPods / Beats (BLE) | CoreBluetooth scan + parse Apple Continuity manufacturer-data broadcasts | Clean-room parser; byte-offset table derived from public reverse-engineering knowledge, not copied from AirBattery |
| Magic Mouse/Keyboard/Trackpad, generic BT HID | IOBluetooth registry + `system_profiler SPBluetoothDataType -json` | Uses stock system CLI, no bundled binaries |
| Generic BLE devices exposing standard GATT Battery Service (`180F`/`2A19`) | CoreBluetooth | Works for any spec-compliant peripheral |
| iPhone / iPad (USB or WiFi) | Shell out to `libimobiledevice` CLI tools (`idevice_id`, `ideviceinfo`) | **Declared as a Homebrew formula dependency**, not bundled — cleaner supply chain than vendoring prebuilt binaries. libimobiledevice is LGPL and is an independent upstream project; depending on it is unrelated to AirBattery's licensing. |
| Apple Watch (via paired iPhone) | Companion-proxy protocol over lockdownd | **Flagged as a research spike** — protocol needs to be independently investigated; if it proves too costly to implement cleanly for v1, ship v1 without Watch support and add it in a point release rather than block launch. |

### Out of v1 core, optional add-on: LAN multi-Mac ("look up another Mac's devices")

Confirmed as wanted (the user owns multiple Macs) but architecturally distinct
from the rest of v1: it requires a small **opt-in, separately-installed
background listener** on each participating Mac (since one Mac must be able to
answer a query at a time it didn't itself initiate). This is the one piece of
the system that can't be fully stateless. Design:
- Independent optional component (e.g. `ibattery-mcp --lan-companion`,
  installed as a `launchd` agent by an explicit opt-in command, not by default).
- Peer discovery via Bonjour/`NWListener` service type advertisement.
- Simple authenticated request/response protocol (shared-secret or local
  pairing token — exact scheme to be detailed in the implementation plan for
  that feature).
- Ships after v1; not a blocker for initial release.

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

- **Bluetooth permission not granted** (`NSBluetoothAlwaysUsageDescription` not
  yet authorized): return an actionable error directing the user to grant
  Bluetooth access in System Settings, rather than crashing or silently
  returning empty results.
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
- LAN multi-Mac companion: authentication scheme and peer-discovery details
  need to be designed in their own follow-up spec before implementation.
