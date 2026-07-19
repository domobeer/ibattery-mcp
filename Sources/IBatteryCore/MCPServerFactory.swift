// Sources/IBatteryCore/MCPServerFactory.swift
import MCP

public func makeServer(registry: DeviceRegistry) async -> Server {
    let server = Server(
        name: "ibattery-mcp",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "get_all_devices_status",
                description: "Get battery and charging status for all Apple devices discoverable from this Mac (this Mac's own battery, plus any nearby Bluetooth devices exposing standard battery reporting).",
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
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "get_all_devices_status":
            let devices = await registry.getAllDevicesStatus()
            var content: [Tool.Content] = [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)]
            let canConnectToHelper = BLEBatterySource.canReachHelper()
            if let warning = bleHelperUnreachableWarning(canConnect: canConnectToHelper) {
                content.append(.text(text: warning, annotations: nil, _meta: nil))
            }
            return .init(content: content, isError: false)

        case "get_device_battery":
            guard let query = params.arguments?["query"]?.stringValue else {
                return .init(content: [.text(text: "Missing required argument: query", annotations: nil, _meta: nil)], isError: true)
            }
            guard let device = await registry.getDeviceBattery(query: query) else {
                return .init(content: [.text(text: "No device found matching '\(query)'", annotations: nil, _meta: nil)], isError: true)
            }
            return .init(content: [.text(text: encodeDevicesAsText([device]), annotations: nil, _meta: nil)], isError: false)

        case "list_known_devices":
            let devices = await registry.listKnownDevices()
            return .init(content: [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)], isError: false)

        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    return server
}
