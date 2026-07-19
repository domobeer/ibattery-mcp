// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ibattery-mcp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "IBatteryCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "ibattery-mcp",
            dependencies: ["IBatteryCore"]
        ),
        .testTarget(
            name: "IBatteryCoreTests",
            dependencies: ["IBatteryCore"]
        )
    ]
)
