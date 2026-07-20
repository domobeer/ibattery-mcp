# ibattery-mcp — Engineering Principles

## Prefer official tools/libraries over reverse-engineered protocols

When a data source needs to talk to Apple hardware or software, delegate any
protocol-level, pairing, or cryptographic work to an already-vetted official
tool or library. Never hand-roll a reverse-engineered protocol (BLE
advertisement decryption, undocumented wire formats, private frameworks)
when an official path already exists — even if the reverse-engineered path
is well documented by third parties.

Established examples:
- iPhone/iPad battery: `idevice_id` / `ideviceinfo` — libimobiledevice's
  public CLI tools.
- Apple Watch battery: `companion_proxy` — libimobiledevice's public,
  documented C API.
- AirPods battery: `system_profiler SPBluetoothDataType -json` — Apple's own
  system tool. Raw Continuity/Proximity Pairing BLE advertisement parsing
  (decrypting Apple's undocumented broadcast protocol) was investigated and
  rejected specifically because this official path already exposes the same
  battery data with far less risk, complexity, and exposure to breaking on
  future macOS/iOS updates.

Our own code should only ever be "call the tool/API, then parse its output."
If a design requires implementing decryption, an undocumented binary
protocol, or a private wire format ourselves, that's a signal to look harder
for an official tool or library that already does it before proceeding.
