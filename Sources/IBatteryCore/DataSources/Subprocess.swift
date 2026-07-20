// Sources/IBatteryCore/DataSources/Subprocess.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Default wall-clock budget for a single `runSubprocess` invocation.
/// External CLI tools normally return in well under a second; this leaves
/// generous headroom for a slow-but-working call while still guaranteeing
/// the watchdog below fires long before anyone would consider the MCP
/// server "hung".
let defaultSubprocessTimeoutSeconds: TimeInterval = 5.0

/// Runs an external CLI tool (`idevice_id`, `ideviceinfo`, `system_profiler`,
/// ...) and captures its stdout/exit code, with a wall-clock watchdog.
///
/// Without this watchdog, a stalled child process (untrusted-but-connected
/// device, wedged `usbmuxd`, a WiFi-paired device dropping mid-call) would
/// block `readDataToEndOfFile()`/`waitUntilExit()` forever, hanging the whole
/// MCP process. That would violate the same "must never hang or crash
/// regardless of external device/hardware flakiness" invariant that
/// `BLEBatterySource`'s socket read-timeouts (`SO_RCVTIMEO`) already
/// guarantee for the Bluetooth path — this brings every subprocess-backed
/// data source to the same standard: if the child hasn't exited within
/// `timeoutSeconds`, it's terminated and treated as a failure (non-zero exit
/// code) instead of hanging the caller indefinitely. A short grace period
/// after `terminate()` escalates to `SIGKILL` in case the child ignores
/// `SIGTERM`, so the guarantee holds even for a misbehaving binary, not just
/// the well-behaved ones we expect in practice.
func runSubprocess(
    _ command: String,
    _ arguments: [String],
    timeoutSeconds: TimeInterval = defaultSubprocessTimeoutSeconds
) -> (stdout: Data, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return (Data(), -1)
    }

    let terminateWorkItem = DispatchWorkItem {
        if process.isRunning {
            process.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: terminateWorkItem)

    // Grace period in case the child ignores SIGTERM; escalate to SIGKILL so
    // the watchdog's guarantee holds unconditionally.
    let killWorkItem = DispatchWorkItem {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds + 2.0, execute: killWorkItem)

    let errDrainThread = Thread {
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
    }
    errDrainThread.start()
    let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    terminateWorkItem.cancel()
    killWorkItem.cancel()
    return (stdoutData, process.terminationStatus)
}
