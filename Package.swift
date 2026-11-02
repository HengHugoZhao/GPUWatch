// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPUWatch",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "GPUWatchCore"),
        .executableTarget(name: "GPUWatch", dependencies: ["GPUWatchCore"]),
        // XCTest ships with Xcode, not the Command Line Tools, so the parser
        // checks are a plain executable: `swift run GPUWatchChecks`.
        .executableTarget(name: "GPUWatchChecks", dependencies: ["GPUWatchCore"]),
    ]
)
