// Sources/ibattery-mcp/main.swift
import IBatteryCore
import MCP

let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource(), IDeviceBatterySource(), WatchBatterySource()])
let server = await makeServer(registry: registry)
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
