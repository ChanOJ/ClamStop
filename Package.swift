// swift-tools-version:5.10
import Foundation
import PackageDescription

// Two editions from one codebase (see docs/app-store-edition.md):
// - full (default): Developer ID, root daemon, Sparkle updates;
// - Mac App Store: `CLAMSTOP_EDITION=appstore swift build`, compiled with `-D APPSTORE`,
//   without Sparkle (App Review rejects self-updating apps).
let appStore = ProcessInfo.processInfo.environment["CLAMSTOP_EDITION"] == "appstore"

var appDependencies: [Target.Dependency] = ["ClamStopShared", "ClamStopDiagnostics"]
var packageDependencies: [Package.Dependency] = []
var appSettings: [SwiftSetting] = []
if appStore {
    appSettings.append(.define("APPSTORE"))
} else {
    // Pinned to an exact release: update deliberately (release notes, then the tools used by
    // scripts/sparkle-tools.sh and release.yml).
    packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"))
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "ClamStop",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: packageDependencies,
    targets: [
        .target(name: "ClamStopShared"),
        // Health check and problem reports (app only: the daemon does not link it).
        .target(name: "ClamStopDiagnostics", dependencies: ["ClamStopShared"]),
        .executableTarget(
            name: "ClamStop",
            dependencies: appDependencies,
            // Copied into ClamStop.app/Contents/Resources by scripts/build-app.sh
            // (not a SwiftPM resource bundle: those break the app's code signature).
            exclude: ["Localization"],
            swiftSettings: appSettings
        ),
        .executableTarget(name: "ClamStopDaemon", dependencies: ["ClamStopShared"]),
        .testTarget(name: "ClamStopTests", dependencies: ["ClamStopShared", "ClamStopDiagnostics"]),
    ]
)
