// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClamStop",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClamStopShared"),
        .executableTarget(
            name: "ClamStop",
            dependencies: ["ClamStopShared"],
            // Copied into ClamStop.app/Contents/Resources by scripts/build-app.sh
            // (not a SwiftPM resource bundle: those break the app's code signature).
            exclude: ["Localization"]
        ),
        .executableTarget(name: "ClamStopDaemon", dependencies: ["ClamStopShared"]),
        .testTarget(name: "ClamStopTests", dependencies: ["ClamStopShared"]),
    ]
)
