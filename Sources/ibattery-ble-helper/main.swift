// Sources/ibattery-ble-helper/main.swift
import Foundation
import IBatteryCore
#if canImport(Darwin)
import Darwin
#endif

setvbuf(stdout, nil, _IONBF, 0)

try? FileManager.default.createDirectory(
    atPath: bleHelperSocketDirectory,
    withIntermediateDirectories: true
)
unlink(bleHelperSocketPath)

let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0 else {
    fatalError("socket() failed: \(errno)")
}

guard var serverAddr = makeUnixSocketAddress(path: bleHelperSocketPath) else {
    fatalError("socket path too long: \(bleHelperSocketPath)")
}
let bindResult = withUnsafePointer(to: &serverAddr) { ptr -> Int32 in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else {
    fatalError("bind() failed: \(errno)")
}
guard listen(serverFD, 4) == 0 else {
    fatalError("listen() failed: \(errno)")
}

print("ibattery-ble-helper listening on \(bleHelperSocketPath)")

DispatchQueue.global(qos: .userInitiated).async {
    while true {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else {
            if errno == EINTR { continue }
            fatalError("accept() failed: \(errno)")
        }

        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = read(clientFD, &buffer, buffer.count)
        guard bytesRead > 0 else {
            close(clientFD)
            continue
        }

        // CBCentralManager must be created on the main thread/actor with
        // RunLoop.main actively running — see this plan's Global Constraints.
        Task { @MainActor in
            let devices = await BLEBatteryScanner().scan(duration: 4.0)
            var responseData = (try? deviceJSONEncoder.encode(devices)) ?? Data("[]".utf8)
            responseData.append(0x0A)
            responseData.withUnsafeBytes { rawBuffer in
                _ = write(clientFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            close(clientFD)
        }
    }
}

RunLoop.main.run()
