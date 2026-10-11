// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DualSenseHaptics",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "DualSenseHaptics", path: "Sources/DualSenseHaptics")
    ]
)
