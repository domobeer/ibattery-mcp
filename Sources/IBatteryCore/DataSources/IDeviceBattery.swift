import Foundation

public func parseDeviceIdList(_ output: String) -> [String] {
    output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

public func parseBatteryPlist(_ data: Data) -> (percentage: Int, isCharging: Bool)? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: Any],
          let percentage = dict["BatteryCurrentCapacity"] as? Int
    else {
        return nil
    }
    let isCharging = dict["BatteryIsCharging"] as? Bool ?? false
    return (percentage, isCharging)
}

public func parseDeviceNamePlist(_ data: Data) -> String? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: Any],
          let name = dict["DeviceName"] as? String
    else {
        return nil
    }
    return name
}

func runLibimobiledeviceTool(_ command: String, _ arguments: [String]) -> (stdout: Data, exitCode: Int32) {
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

    var stdoutData = Data()
    let errDrainThread = Thread {
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
    }
    errDrainThread.start()
    stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (stdoutData, process.terminationStatus)
}

public struct IDeviceStatus: Sendable, Equatable {
    public let toolsInstalled: Bool
    /// Count of devices detected but not readable; a catch-all for any per-device fetch failure
    /// (untrusted pairing, malformed battery data, or device disconnected mid-enumeration).
    public let connectedButUnreadableCount: Int
}

public struct IDeviceBatterySource: BatteryDataSource {
    public init() {}

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.fetchAllBlocking().devices)
            }
        }
    }

    public static func checkStatus() -> IDeviceStatus {
        fetchAllBlocking().status
    }

    private static func fetchAllBlocking() -> (devices: [DeviceBatteryInfo], status: IDeviceStatus) {
        let idResult = runLibimobiledeviceTool("idevice_id", ["-l"])
        guard idResult.exitCode == 0 else {
            return ([], IDeviceStatus(toolsInstalled: false, connectedButUnreadableCount: 0))
        }

        let output = String(data: idResult.stdout, encoding: .utf8) ?? ""
        let udids = parseDeviceIdList(output)

        var devices: [DeviceBatteryInfo] = []
        for udid in udids {
            if let info = fetchDeviceInfo(udid: udid) {
                devices.append(info)
            }
        }

        let unreadableCount = udids.count - devices.count
        return (devices, IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: unreadableCount))
    }

    private static func fetchDeviceInfo(udid: String) -> DeviceBatteryInfo? {
        let batteryResult = runLibimobiledeviceTool("ideviceinfo", ["-u", udid, "-q", "com.apple.mobile.battery", "-x"])
        guard batteryResult.exitCode == 0,
              let battery = parseBatteryPlist(batteryResult.stdout)
        else {
            return nil
        }

        let identityResult = runLibimobiledeviceTool("ideviceinfo", ["-u", udid, "-x"])
        let name = (identityResult.exitCode == 0 ? parseDeviceNamePlist(identityResult.stdout) : nil) ?? udid

        return DeviceBatteryInfo(
            id: udid,
            name: name,
            kind: .iosDevice,
            percentage: battery.percentage,
            isCharging: battery.isCharging,
            lastUpdated: Date()
        )
    }
}
