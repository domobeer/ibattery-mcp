// Sources/ibattery-mcp/main.swift
import Foundation
import IBatteryCore
import MCP

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--help" || CommandLine.arguments[1] == "-h" {
    print("""
    ibattery-mcp - MCP server exposing Apple device battery status as AI-assistant tools

    Usage: ibattery-mcp

    This is a Model Context Protocol (MCP) server that communicates over stdio
    using JSON-RPC. It is meant to be launched by an MCP-compatible client (e.g.
    Claude Desktop, Claude Code) rather than run interactively from a terminal.

    Options:
      --help, -h    Show this help message and exit
    """)
    exit(0)
}

let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource(), IDeviceBatterySource(), WatchBatterySource()])
let server = await makeServer(registry: registry)
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
