// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "about-time",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "about-time-cli", targets: ["AboutTimeCLI"])
    ],
    targets: [
        .executableTarget(
            name: "AboutTimeCLI",
            path: "Sources/AboutTimeCLI",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AboutTimeCLITests",
            dependencies: ["AboutTimeCLI"],
            path: "Tests/AboutTimeCLITests"
        )
    ]
)
