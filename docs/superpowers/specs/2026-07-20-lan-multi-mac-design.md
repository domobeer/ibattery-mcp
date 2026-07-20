# LAN Multi-Mac Support — Design Doc (Decision: Not Pursued)

Date: 2026-07-20
Status: Rejected during brainstorming — recorded for future reference

## 1. What was being considered

Querying another Mac's devices (its own battery, iPhone/iPad, Apple Watch,
AirPods, Bluetooth accessories) over the local network from this Mac's
`ibattery-mcp` instance — the last of the two originally-deferred features
(AirPods shipped first; see
[its design doc](./2026-07-20-airpods-battery-design.md)).

## 2. Why this is fundamentally different from iPhone/Watch/AirPods

Every other data source this project implements works by reading data that
**macOS or iOS already collects and syncs on its own**, for reasons
unrelated to this project:

- iPhone/iPad and Apple Watch: `lockdownd`'s pairing relationship and the
  `companion_proxy` service already exist as part of normal device
  management — `libimobiledevice` just exposes that existing channel.
- AirPods: battery status is already synced to every device signed into
  the same iCloud account (Apple's "Automatic Device Switching" key
  sharing), so this Mac's own Bluetooth stack already silently knows about
  it — `system_profiler` just surfaces what's already there.

There is no equivalent for "another Mac's battery." Find My can show it in
Apple's own UI, but only through a closed, cloud-based path with no local
or scriptable API. Nothing on macOS silently syncs one Mac's device status
to another Mac the way it does for Apple's own peripherals. AirBattery's
own implementation confirms this: it doesn't read an existing channel, it
runs a full custom peer-to-peer app (via `MultipeerKit`, a wrapper around
Apple's `MultipeerConnectivity` framework) on every machine involved, with
its own discovery, authentication (a user-configured shared passphrase,
`ncGroupID`, gating an application-level encrypted payload), and message
protocol. There was no "read the existing data" shortcut available to it
either — this is the actual cost of the feature, not an implementation
choice AirBattery made unnecessarily.

## 3. What the design would have required

Investigated during brainstorming, in order:

1. **Permission model risk.** AirBattery's own Xcode project declares
   `NSLocalNetworkUsageDescription` in a real, `open`-launched `.app`
   bundle (`LSUIElement = YES`) — the same shape as the Bluetooth
   responsible-process problem this project already solved once. A quick
   probe (bare CLI binary advertising + browsing a Bonjour service on this
   single Mac, self-discovery only) completed without a visible permission
   prompt, but this is inconclusive: it doesn't rule out a permission
   requirement for genuine cross-machine traffic on a machine that has
   never granted Local Network access to anything in this process's
   responsible-process chain before. The conservative reading, matching
   AirBattery's own choice, is to assume a second persistent
   `.app`-launched helper (`ibattery-lan-helper`, kept separate from
   `ibattery-ble-helper` — CoreBluetooth and MultipeerConnectivity/Bonjour
   are different technical domains) would be needed, exactly like the
   Bluetooth helper.
2. **Symmetric peer requirement.** Unlike the Bluetooth helper (which only
   needs to run on the Mac being queried), querying *another* Mac requires
   that Mac to also run the same helper — collecting its own full local
   battery/device status and serving it to peers. This is a genuinely
   different shape from every other source in this project: a piece of
   this project's own software has to be installed and running on hardware
   outside the user's own Mac (or on another Mac they also own, but still
   a second real deployment).
3. **Authentication.** Broadcasting device names (which routinely embed a
   real name, e.g. "猫仔的iPhone17") and battery levels on the local
   network without any access control would let anyone else on the same
   network (a shared or guest WiFi) discover and query that data.
   AirBattery's answer — a shared passphrase configured identically on
   every Mac, silently ignoring peers whose passphrase doesn't match —
   was judged sound and was the leading candidate, but was never finalized
   since the feature was dropped before this step was needed.

## 4. Decision

Not pursued. Weighed against the other three features (each of which
turned out to be "call an official tool or library that already has the
data"), this one requires building and shipping an entirely new
peer-to-peer networking stack with its own permission model and
authentication design, with no official channel to lean on — a
qualitatively larger and riskier undertaking than the rest of this
project's scope. The user made this call directly after seeing the real
cost laid out during brainstorming, not because of a technical dead end.

If revisited in the future, the starting points above (a separate
`ibattery-lan-helper`, `MultipeerConnectivity` used directly rather than
via the third-party `MultipeerKit` wrapper to avoid an extra dependency,
shared-passphrase authentication) are still the leading design candidates.
