// Sources/IBatteryCore/BLEHelperIPC.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public let bleHelperSocketDirectory: String = {
    ("~/Library/Application Support/ibattery-mcp" as NSString).expandingTildeInPath
}()

public let bleHelperSocketPath: String = {
    bleHelperSocketDirectory + "/ble-helper.sock"
}()

public func makeUnixSocketAddress(path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)

    // sockaddr_un.sun_path is exactly 104 bytes; need room for null terminator
    guard pathBytes.count < 104 else { return nil }

    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr.pointee)) { charPtr in
            for (i, byte) in pathBytes.enumerated() {
                charPtr[i] = CChar(bitPattern: byte)
            }
            charPtr[pathBytes.count] = 0
        }
    }
    return addr
}
