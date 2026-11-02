// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevClean",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure system-reading logic, no UI, so it can be unit tested.
        .target(name: "DevCleanCore"),
        // The menu-bar app.
        .executableTarget(name: "DevClean", dependencies: ["DevCleanCore"]),
        .testTarget(name: "DevCleanCoreTests", dependencies: ["DevCleanCore"]),
    ]
)
