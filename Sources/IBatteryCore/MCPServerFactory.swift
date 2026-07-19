// Sources/IBatteryCore/MCPServerFactory.swift
import MCP

public func makeServer() async -> Server {
    let server = Server(
        name: "ibattery-mcp",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [])
    }

    await server.withMethodHandler(CallTool.self) { params in
        return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
    }

    return server
}
