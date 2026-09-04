// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "tydo-cli",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "tydo", targets: ["TydoCLI"])],
    targets: [
        .executableTarget(
            name: "TydoCLI",
            path: "tydo",
            exclude: ["App", "Capture", "Hotkeys", "List", "Options"]
        ),
        .testTarget(
            name: "TydoCLITests",
            path: "Tests/TydoCLITests"
        )
    ]
)
