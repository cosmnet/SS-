// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SSPlus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SSPlus",
            path: "Sources/SSPlus"
        )
    ]
)
