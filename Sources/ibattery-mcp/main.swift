// Sources/ibattery-mcp/main.swift
import IBatteryCore
import MCP

let server = await makeServer()
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
