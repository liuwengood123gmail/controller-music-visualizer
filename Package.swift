// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ControllerMusicVisualizer",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "ControllerMusicVisualizer", path: "Sources/ControllerMusicVisualizer")
    ]
)
