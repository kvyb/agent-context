// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "agent-context",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "agent-context", targets: ["AgentContext"])
    ],
    targets: [
        .executableTarget(
            name: "AgentContext",
            path: "Sources/AgentContext",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AgentContextTests",
            dependencies: ["AgentContext"],
            path: "Tests/AgentContextTests"
        )
    ]
)
