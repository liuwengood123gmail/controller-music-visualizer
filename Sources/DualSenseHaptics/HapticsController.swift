import Combine
import CoreAudio
import Foundation
import AppKit
import GameController

enum Source: String, CaseIterable, Identifiable {
    case music = "跟随音乐"
    case massage = "按摩"
    var id: Self { self }
}

/// 当前手柄的连接方式（只用于显示）
private enum Link: Equatable {
    case none
    case usb(AudioObjectID)
    case bluetooth
}

@MainActor
final class HapticsController: ObservableObject {
    @Published var source: Source = .music { didSet { if running && source != oldValue { restart() } } }
    @Published var musicMode: MusicMode = .beat { didSet { analyzer.mode = musicMode } }
    @Published var sensitivity: Float = 0.5 { didSet { analyzer.sensitivity = sensitivity } }
    @Published var responsiveness: Float = 0.7 { didSet { analyzer.responsiveness = responsiveness } }
    @Published var preset: MassagePreset = .knead
    /// 0...2：超过 1 时把中低强度整体拉高，顶端削平在硬件上限
    @Published var intensity: Float = 1
    @Published var speed: Double = 1

    @Published var triggerResistance: Float = 0.5
    @Published var triggerAdjustsIntensity = true
    @Published var lightSpeed: Float = 0.3 { didSet { analyzer.lightSpeed = lightSpeed } }
    /// 灯条亮暗变化幅度：1 = 鼓点间完全暗掉，越小保留的底亮度越高
    @Published var lightRange: Float = 1
    @Published var lightEffects = true { didSet { if !lightEffects { resetLight() } } }

    @Published private(set) var running = false
    @Published private(set) var status = "未连接手柄"
    @Published private(set) var engineName = "—"
    @Published private(set) var level: (Float, Float) = (0, 0)
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?

    private let analyzer = MusicAnalyzer()
    private let features = ControllerFeatures()
    private var tap: SystemAudioTap?
    private var tapGeneration = 0
    private var output: HapticOutput?
    private var hid: DualSenseHID?
    private var meter: (Float, Float) = (0, 0)
    private var timer: Timer?
    private var link: Link = .none
    private var massageTime: Double = 0
    private var lastTick = Date()
    private var frame = 0

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.features.invalidate() }
        }
        CA.onDevicesChanged { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        GCController.startWirelessControllerDiscovery {}
        link = currentLink()
        updateStatus()

        // 调试用：open DualSenseHaptics.app --args --autostart
        if CommandLine.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
    }

    private var controller: GCController? {
        GCController.controllers().first { $0.extendedGamepad is GCDualSenseGamepad }
            ?? GCController.controllers().first { $0.haptics != nil }
    }

    private func currentLink() -> Link {
        if let dev = CA.dualSenseOutputDevice() { return .usb(dev) }
        return controller != nil ? .bluetooth : .none
    }

    private func updateStatus() {
        switch link {
        case .usb: status = "DualSense · USB"
        case .bluetooth: status = "\(controller?.vendorName ?? "手柄") · 蓝牙"
        case .none: status = "未连接手柄"
        }
    }

    /// 设备列表变化。注意：本 App 创建/销毁采集用的聚合设备也会触发这里，
    /// 所以只有手柄连接方式真的变了才重启，否则会无限重启卡死主线程。
    private func devicesChanged() {
        let newLink = currentLink()
        features.attach(controller)
        guard newLink != link else { return }
        link = newLink
        updateStatus()
        if running { restart() }
    }

    // MARK: - 开始 / 停止

    func toggle() { running ? stop() : start() }

    func start() {
        errorMessage = nil
        link = currentLink()
        updateStatus()
        features.attach(controller)

        guard let c = controller else {
            errorMessage = "没有找到 DualSense 手柄"
            return
        }
        // 优先直接发 HID 报告（后台也能保持扳机阻尼/灯条）；打不开再退回 GameController
        if let h = DualSenseHID.open() {
            hid = h
            output = h
        } else {
            do {
                output = try RumbleHapticOutput(controller: c)
            } catch {
                errorMessage = "系统的手柄震动服务连接失败（\((error as NSError).code)）。请拔插一次手柄；仍不行就在终端运行 sudo killall gamecontrollerd 重启该服务，然后重新点开始。"
            }
        }
        engineName = output?.name ?? "震动不可用"
        NSLog("DualSenseHaptics engine: %@", engineName)

        if source == .music { startTap() }

        massageTime = 0
        lastTick = Date()
        let tm = Timer(timeInterval: 1.0 / 100, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        running = true
    }

    /// 系统声音采集放到后台线程启动：第一次会等用户回答「系统录音」权限弹窗，
    /// 这期间 Core Audio 调用会一直阻塞，放主线程会把整个界面卡死。
    private func startTap() {
        analyzer.reset()
        tapGeneration += 1
        let generation = tapGeneration
        let t = SystemAudioTap()
        t.onAudio = { [analyzer] l, r, n, sr in analyzer.process(left: l, right: r, frames: n, sampleRate: sr) }
        let pending = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.tapGeneration == generation, self.tap == nil else { return }
                self.notice = "正在等待「系统录音」授权，请在弹出的对话框里点「允许」（可能出现在另一块屏幕上）"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: pending)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try t.start() }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    pending.cancel()
                    guard let self, self.tapGeneration == generation, self.running else {
                        t.stop()   // 等授权期间已经停止或切换了模式
                        return
                    }
                    self.notice = nil
                    if case .failure(let failure) = result {
                        self.errorMessage = "无法读取系统声音：\(failure)。请在 系统设置 → 隐私与安全性 → 录屏与系统录音 里允许本 App。"
                    } else {
                        self.tap = t
                    }
                }
            }
        }
    }

    func stop() {
        tapGeneration += 1
        notice = nil
        timer?.invalidate()
        timer = nil
        tap?.stop()
        tap = nil
        output?.set(left: 0, right: 0)
        output?.stop()
        output = nil
        hid = nil
        features.reset()
        running = false
        engineName = "—"
        level = (0, 0)
    }

    private func restart() {
        stop()
        start()
    }

    // MARK: - 每 10ms 计算一次

    private func tick() {
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastTick))
        lastTick = now
        frame += 1

        // 扳机：R2 加强度，L2 减强度，按得越深变得越快
        // 在后台时系统会重置扳机/灯条，每 0.5 秒补发一次
        if let hid {
            hid.setTriggerResistance(triggerResistance)
        } else {
            if !NSApplication.shared.isActive && frame % 50 == 0 { features.invalidate() }
            features.setTriggerResistance(triggerResistance)
        }
        if triggerAdjustsIntensity {
            let (lt, rt) = features.triggers
            let dz: (Float) -> Float = { $0 < 0.05 ? 0 : $0 * $0 }
            let delta = (dz(rt) - dz(lt)) * 1.0 * dt
            if delta != 0 { intensity = min(max(intensity + delta, 0), 2) }
        }

        var l: Float, r: Float
        var music = MusicFrame()
        switch source {
        case .music:
            music = analyzer.current
            (l, r) = music.vibration
        case .massage:
            massageTime += Double(dt) * speed
            (l, r) = preset.sample(massageTime)
            music.level = (l, r)   // 按摩时灯光直接跟随按摩波形
            music.meter = (l, r)
        }
        l = min(max(l * intensity, 0), 1)
        r = min(max(r * intensity, 0), 1)
        output?.set(left: l, right: r)
        level = (l, r)

        // 灯光用强度之前的原始数值，强度调低也照样跳
        if lightEffects { updateLight(music) }
    }

    private func resetLight() {
        if let hid { hid.setLight(0, 0.25, 1) } else { features.reset() }
    }

    private func updateLight(_ m: MusicFrame) {
        let r: Float, g: Float, b: Float
        switch source {
        case .music:
            // 三色混合：低频红、中频绿、高频蓝，各自跟随能量（底鼓+人声=黄，人声+镲片=青，全部=白）
            let v = (1 - lightRange) + lightRange * m.barLevel
            (r, g, b) = (m.color.r * v, m.color.g * v, m.color.b * v)
        case .massage:
            // 预设固定颜色，亮度跟随按摩波形
            let v = (1 - lightRange) + lightRange * (0.15 + 0.85 * max(m.level.0, m.level.1))
            (r, g, b) = hsv(preset.hue(massageTime), 1, v)
        }
        if let hid {
            hid.setLight(r, g, b)
            hid.setPlayerLEDs(playerLEDMask(left: m.meter.0, right: m.meter.1))
        } else {
            features.setLight(r, g, b)
        }
    }

    /// 下方 5 颗白灯做成从中间向两边跳的立体声电平灯，跟随整体音量近似实时；
    /// 只留约 80ms 的余晖防止在门槛边缘闪烁
    private func playerLEDMask(left: Float, right: Float) -> UInt8 {
        let fall: Float = 0.12   // 每 10ms 最多下降 0.12
        meter.0 = max(left, meter.0 - fall)
        meter.1 = max(right, meter.1 - fall)
        var mask: UInt8 = 0
        if max(meter.0, meter.1) > 0.15 { mask |= 0b00100 }   // 中间
        if meter.0 > 0.45 { mask |= 0b00010 }
        if meter.0 > 0.8 { mask |= 0b00001 }
        if meter.1 > 0.45 { mask |= 0b01000 }
        if meter.1 > 0.8 { mask |= 0b10000 }
        return mask
    }
}
