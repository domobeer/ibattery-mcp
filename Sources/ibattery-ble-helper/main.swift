// Sources/ibattery-ble-helper/main.swift
import Foundation
import IBatteryCore
#if canImport(Darwin)
import Darwin
#endif

setvbuf(stdout, nil, _IONBF, 0)

// Without this, a write() to a client socket whose peer (the ibattery-mcp
// process) has already exited or closed its end of the connection — e.g.
// the MCP host killed it mid-request, before this helper finished its ~4s
// BLE scan and tried to write the response back — raises SIGPIPE, whose
// default disposition terminates the whole process. That would kill this
// persistent background helper, defeating the entire point of "launch it
// once, it stays running." Ignoring SIGPIPE process-wide makes write()
// return EPIPE as an ordinary error instead, which the write() call sites
// below already tolerate (they discard the return value). This must be set
// before any sockets are created/used below.
signal(SIGPIPE, SIG_IGN)

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
            switch errno {
            case EINTR, ECONNABORTED, EMFILE, ENFILE:
                // Recoverable: an interrupted syscall, a pending connection
                // that was aborted before accept() returned, or transient
                // file-descriptor exhaustion. The listening socket itself is
                // still fine in all of these cases, so log and keep serving
                // rather than taking down the whole persistent helper over
                // a single blip.
                print("accept() recoverable error (errno \(errno)), continuing")
                continue
            default:
                // Anything else (e.g. EBADF, EINVAL, ENOTSOCK) means the
                // listening socket itself is broken — retrying accept()
                // won't help, so there's nothing left to do but stop.
                fatalError("accept() failed: \(errno)")
            }
        }

        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = read(clientFD, &buffer, buffer.count)
        guard bytesRead > 0 else {
            close(clientFD)
            continue
        }

        let requestText = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // CBCentralManager must be created on the main thread/actor with
        // RunLoop.main actively running — see this plan's Global Constraints.
        Task { @MainActor in
            var responseData: Data
            if requestText == "status" {
                // Lightweight Bluetooth-state check — no scanning involved,
                // resolves as soon as the first state callback fires. See
                // BLEHelperBluetoothStatus for the wire shape.
                let status = await BLEBluetoothStatusChecker().checkStatus()
                responseData = (try? deviceJSONEncoder.encode(status)) ?? Data("{}".utf8)
            } else {
                // "scan" (or anything else, kept for backward compatibility)
                // — unchanged full scan behavior.
                let devices = await BLEBatteryScanner().scan(duration: 4.0)
                responseData = (try? deviceJSONEncoder.encode(devices)) ?? Data("[]".utf8)
            }
            responseData.append(0x0A)
            responseData.withUnsafeBytes { rawBuffer in
                _ = write(clientFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            close(clientFD)
        }
    }
}

RunLoop.main.run()
