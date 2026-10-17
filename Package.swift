// swift-tools-version: 5.10
import PackageDescription

// ControllerCore：与平台无关的核心（音乐分析、会话引擎、报告构造、音频渲染、设置、引擎接口），
// 在 macOS / Linux 上都能编译和测试；以后也编译到 Android / Windows。
// ControllerMusicVisualizer：macOS App（SwiftUI 界面 + CoreAudio / IOKit / GameController 适配），只在 macOS 上构建。
var targets: [Target] = [
    .target(name: "ControllerCore", path: "Sources/ControllerCore"),
    // C 接口：Android（JNI 薄层）/ 以后 Windows（P/Invoke）调用核心用
    .target(name: "ControllerCAPI", dependencies: ["ControllerCore"], path: "Sources/ControllerCAPI"),
    .testTarget(name: "ControllerCAPITests", dependencies: ["ControllerCAPI", "ControllerCore"], path: "Tests/ControllerCAPITests"),
    .testTarget(name: "ControllerCoreTests", dependencies: ["ControllerCore"], path: "Tests/ControllerCoreTests"),
    // 不用 @testable：只通过公开接口调用，保证 macOS App（另一个模块）能用到的东西确实是 public 的
    .testTarget(name: "ControllerCoreAPITests", dependencies: ["ControllerCore"], path: "Tests/ControllerCoreAPITests"),
]
#if os(macOS)
targets.append(.executableTarget(name: "ControllerMusicVisualizer", dependencies: ["ControllerCore"],
                                 path: "Sources/ControllerMusicVisualizer"))
#endif

let package = Package(
    name: "ControllerMusicVisualizer",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ControllerCore", targets: ["ControllerCore"]),
        // Android 打包进 APK 的 libControllerCAPI.so
        .library(name: "ControllerCAPI", type: .dynamic, targets: ["ControllerCAPI"]),
    ],
    targets: targets
)
