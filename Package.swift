// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SSPlus",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "SSPlus",
            path: "Sources/SSPlus",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
