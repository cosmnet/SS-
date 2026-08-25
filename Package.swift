// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SSPlus",
    platforms: [.macOS(.v10_15)],
    targets: [
        .executableTarget(
            name: "SSPlus",
            path: "Sources/SSPlus",
            linkerSettings: [
                // macOS 10.15–11: Swift eşzamanlılık çalışma zamanı sistemde yok;
                // build_app.sh libswift_Concurrency.dylib'i Contents/Frameworks'e koyar.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
