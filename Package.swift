// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClamStop",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClamStopShared"),
        .executableTarget(name: "ClamStop", dependencies: ["ClamStopShared"]),
        .executableTarget(name: "ClamStopDaemon", dependencies: ["ClamStopShared"]),
        .testTarget(name: "ClamStopTests", dependencies: ["ClamStopShared"]),
    ]
)
