// DualSense 手柄测试：信息 / 灯条 / 震动 / 自适应扳机 / 按键
import Foundation
import GameController
import CoreHaptics

setvbuf(stdout, nil, _IONBF, 0)
GCController.shouldMonitorBackgroundEvents = true

func log(_ s: String) { print(s) }

var engines: [CHHapticEngine] = []

func rumble(_ c: GCController, _ locality: GCHapticsLocality, _ name: String, seconds: Double = 0.8) {
    guard let haptics = c.haptics, haptics.supportedLocalities.contains(locality),
          let engine = haptics.createEngine(withLocality: locality) else {
        log("  ✗ \(name): 不支持"); return
    }
    do {
        try engine.start()
        engines.append(engine)
        let ev = CHHapticEvent(eventType: .hapticContinuous,
                               parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                               relativeTime: 0, duration: seconds)
        let player = try engine.makePlayer(with: try CHHapticPattern(events: [ev], parameters: []))
        try player.start(atTime: 0)
        log("  ▶ 震动：\(name)")
    } catch { log("  ✗ \(name) 出错: \(error)") }
    Thread.sleep(forTimeInterval: seconds + 0.5)
}

// 需要测试的按键
let required = ["Button A", "Button B", "Button X", "Button Y",
                "Left Shoulder", "Right Shoulder", "Left Trigger", "Right Trigger",
                "Left Thumbstick Button", "Right Thumbstick Button",
                "Button Menu", "Button Options", "Button Home",
                "Touchpad Button",
                "Direction Pad Up", "Direction Pad Down", "Direction Pad Left", "Direction Pad Right",
                "Left Thumbstick Up", "Left Thumbstick Down", "Left Thumbstick Left", "Left Thumbstick Right",
                "Right Thumbstick Up", "Right Thumbstick Down", "Right Thumbstick Left", "Right Thumbstick Right"]
let display: [String: String] = [
    "Button A": "✕", "Button B": "○", "Button X": "□", "Button Y": "△",
    "Left Shoulder": "L1", "Right Shoulder": "R1", "Left Trigger": "L2", "Right Trigger": "R2",
    "Left Thumbstick Button": "L3", "Right Thumbstick Button": "R3",
    "Button Menu": "Options", "Button Options": "Create", "Button Home": "PS",
    "Touchpad Button": "触控板按下",
]
var seen = Set<String>()
var lastTrigger: [String: Int] = [:]

func mark(_ key: String, _ text: String) {
    let new = !seen.contains(key) && required.contains(key)
    seen.insert(key)
    log("  \(text)\(new ? "   [新 ✓ \(seen.intersection(required).count)/\(required.count)]" : "")")
}

func runTest(_ c: GCController) {
    log("\n=== 1. 手柄信息 ===")
    log("  名称: \(c.vendorName ?? "?")  类别: \(c.productCategory)")
    if let b = c.battery {
        let st = [GCDeviceBattery.State.discharging: "放电中", .charging: "充电中", .full: "已充满"][b.batteryState] ?? "未知"
        log("  电量: \(Int(b.batteryLevel * 100))%  状态: \(st)")
    }
    log("  支持震动: \(c.haptics != nil)  支持灯条: \(c.light != nil)")

    log("\n=== 2. 灯条颜色 ===")
    if let light = c.light {
        for (n, r, g, b) in [("红", 1.0, 0.0, 0.0), ("绿", 0.0, 1.0, 0.0), ("蓝", 0.0, 0.0, 1.0), ("白", 1.0, 1.0, 1.0)] {
            light.color = GCColor(red: Float(r), green: Float(g), blue: Float(b))
            log("  灯条 → \(n)")
            Thread.sleep(forTimeInterval: 0.8)
        }
        light.color = GCColor(red: 0, green: 0.3, blue: 1)
    }

    log("\n=== 3. 震动 ===")
    rumble(c, .leftHandle, "左侧马达")
    rumble(c, .rightHandle, "右侧马达")
    rumble(c, .handles, "左右同时")

    log("\n=== 4. 自适应扳机 ===")
    if let ds = c.extendedGamepad as? GCDualSenseGamepad {
        ds.leftTrigger.setModeFeedbackWithStartPosition(0.1, resistiveStrength: 1.0)
        ds.rightTrigger.setModeVibrationWithStartPosition(0.1, amplitude: 1.0, frequency: 0.3)
        log("  L2 = 强阻力模式（按下应感觉很硬）")
        log("  R2 = 振动模式（按下应感觉扳机在抖）")
    } else { log("  不是 DualSense，跳过") }

    log("\n=== 5. 按键测试（90 秒，全部按完自动结束）===")
    log("  请依次按：✕ ○ □ △  L1 R1 L2 R2  L3 R3  Options Create PS  触控板按下")
    log("  方向键上下左右，左右摇杆各推上下左右；也可以在触控板上滑动\n")

    guard let pad = c.extendedGamepad else { return }
    pad.valueChangedHandler = { gp, el in
        if let dp = el as? GCControllerDirectionPad {
            let name = dp.aliases.first ?? "?"
            let base = name.contains("Left Thumbstick") ? "Left Thumbstick" :
                       name.contains("Right Thumbstick") ? "Right Thumbstick" :
                       name.contains("Touchpad") ? "Touchpad" : "Direction Pad"
            let x = dp.xAxis.value, y = dp.yAxis.value
            if base == "Touchpad" {
                if abs(x) > 0.01 || abs(y) > 0.01, !seen.contains("touch") {
                    seen.insert("touch"); log("  触控板触摸 ✓ (x=\(String(format: "%.2f", x)), y=\(String(format: "%.2f", y)))")
                }
                return
            }
            for (dir, active) in [("Up", y > 0.6), ("Down", y < -0.6), ("Left", x < -0.6), ("Right", x > 0.6)] where active {
                let key = "\(base) \(dir)"
                if !seen.contains(key) { mark(key, "\(base == "Direction Pad" ? "方向键" : (base.hasPrefix("Left") ? "左摇杆" : "右摇杆")) \(dir)") }
            }
            return
        }
        if let btn = el as? GCControllerButtonInput {
            let name = btn.aliases.first ?? "?"
            if name.contains("Trigger") {
                let step = Int(btn.value * 4)  // 0..4，只在档位变化时打印
                if lastTrigger[name] != step {
                    lastTrigger[name] = step
                    let label = display[name] ?? name
                    if step > 0 { mark(name, "\(label) 压力 \(Int(btn.value * 100))%") }
                }
                return
            }
            if btn.isPressed { mark(name, "按下 \(display[name] ?? name)") }
        }
    }
}

var started = false
func tryStart() {
    guard !started, let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }) else { return }
    started = true
    DispatchQueue.global().async {
        runTest(c)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && !Set(required).isSubset(of: seen) { Thread.sleep(forTimeInterval: 0.2) }
        DispatchQueue.main.async {
            if let ds = c.extendedGamepad as? GCDualSenseGamepad {
                ds.leftTrigger.setModeOff(); ds.rightTrigger.setModeOff()
            }
            let missing = required.filter { !seen.contains($0) }.map { display[$0] ?? $0 }
            log("\n=== 结果 ===")
            log("  已检测 \(required.count - missing.count)/\(required.count)  触控板触摸: \(seen.contains("touch") ? "✓" : "未测")")
            log(missing.isEmpty ? "  全部按键正常 ✅" : "  未检测到: \(missing.joined(separator: ", "))")
            exit(0)
        }
    }
}

NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { _ in tryStart() }
log("正在查找手柄…")
GCController.startWirelessControllerDiscovery {}
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryStart() }
DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if !started { log("8 秒内没找到手柄"); exit(1) } }
RunLoop.main.run()
