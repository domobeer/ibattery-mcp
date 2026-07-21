// Sources/IBatteryCore/MCPServerFactory.swift
import MCP

public func makeServer(registry: DeviceRegistry) async -> Server {
    let server = Server(
        name: "ibattery-mcp",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: makeToolDefinitions())
    }

    await server.withMethodHandler(CallTool.self) { params in
        await handleCallTool(params: params, registry: registry)
    }

    return server
}

private func makeToolDefinitions() -> [Tool] {
    [
        Tool(
            name: "get_all_devices_status",
            description: """
            Get battery and charging status for all Apple devices discoverable from this Mac: \
            this Mac's own battery, nearby Bluetooth devices exposing standard battery reporting, \
            a paired iPhone/iPad (over USB/WiFi sync, or — even while locked — via a Bluetooth \
            battery read), an Apple Watch reachable through that iPhone, and AirPods (or other \
            Apple-vendor earbuds) known to this Mac's Bluetooth stack, including per-bud \
            in-case status and charging state when they're nearby and broadcasting.
            """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([:])
            ])
        ),
        Tool(
            name: "get_device_battery",
            description: "Get battery status for one device matching a name or type query, e.g. 'MacBook' or 'Keyboard'.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object([
                        "type": "string",
                        "description": "Device name or type substring to search for"
                    ])
                ]),
                "required": .array(["query"])
            ])
        ),
        Tool(
            name: "list_known_devices",
            description: "List devices seen during this session without triggering a new scan.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:])
            ])
        )
    ]
}

private func handleCallTool(params: CallTool.Parameters, registry: DeviceRegistry) async -> CallTool.Result {
    switch params.name {
    case "get_all_devices_status":
        return await handleGetAllDevicesStatus(registry: registry)

    case "get_device_battery":
        return await handleGetDeviceBattery(params: params, registry: registry)

    case "list_known_devices":
        let devices = await registry.listKnownDevices()
        return .init(content: [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)], isError: false)

    default:
        return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
    }
}

private func handleGetAllDevicesStatus(registry: DeviceRegistry) async -> CallTool.Result {
    let devices = await registry.getAllDevicesStatus()
    var content: [Tool.Content] = [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)]
    let bluetoothStatus = BLEBatterySource.fetchBluetoothStatus()
    if let warning = bleHelperStatusWarning(status: bluetoothStatus) {
        content.append(.text(text: warning, annotations: nil, _meta: nil))
    }
    let iDeviceStatus = IDeviceBatterySource.checkStatus()
    if let warning = iDeviceStatusWarning(status: iDeviceStatus) {
        content.append(.text(text: warning, annotations: nil, _meta: nil))
    }
    return .init(content: content, isError: false)
}

private func handleGetDeviceBattery(params: CallTool.Parameters, registry: DeviceRegistry) async -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue else {
        return .init(content: [.text(text: "Missing required argument: query", annotations: nil, _meta: nil)], isError: true)
    }
    guard let device = await registry.getDeviceBattery(query: query) else {
        var message = "No device found matching '\(query)'"
        let bluetoothStatus = BLEBatterySource.fetchBluetoothStatus()
        if let warning = bleHelperStatusWarning(status: bluetoothStatus) {
            message += "\n\n\(warning)"
        }
        let iDeviceStatus = IDeviceBatterySource.checkStatus()
        if let warning = iDeviceStatusWarning(status: iDeviceStatus) {
            message += "\n\n\(warning)"
        }
        return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
    return .init(content: [.text(text: encodeDevicesAsText([device]), annotations: nil, _meta: nil)], isError: false)
}
