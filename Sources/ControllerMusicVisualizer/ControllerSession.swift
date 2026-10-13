import AppKit
import Combine
import CoreAudio
import Foundation
import GameController

/// 一个手柄的运行时：持有它自己的设置、输出通道、按摩时间、灯条 / 震动整形状态和电平。
/// 由 `AppModel` 的 100Hz 主循环依次调用 `tick`。
@MainActor
final class ControllerSession: ObservableObject, Identifiable {
    /// 会话的稳定编号（界面选中项用）；手柄换了连接方式（USB ↔ 蓝牙）时编号不变
    let id = UUID()
    private(set) var identity: ControllerIdentity

    @Published var settings: ControllerSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var hidInfo: DualSenseInfo?
    @Published private(set) var gc: GCController?

    /// 输出通道是否在运行
    @Published private(set) var isActive = false
    @Published private(set) var battery: (level: Int, charging: Bool)?
    @Published private(set) var engineName = Bilingual(zh: "—", en: "—")
    @Published private(set) var level: (Float, Float) = (0, 0)
    /// 随机按摩当前轮播到的预设（界面显示用）
    @Published private(set) var randomNow: MassagePreset?
    @Published private(set) var errorMessage: Bilingual?

    /// 全局「开始」是否按下
    private(set) var armed = false

    private let waveform: HapticWaveform
    private let features = ControllerFeatures()
    private var input: DualSenseInput?
    private var output: HapticOutput?
    private var hid: DualSenseHID?
    private var hd: HDHapticOutput?
    private var massageTime: Double = 0
    private var vibration = VibrationShaper()
    private var lightShaper = LightShaper()
    private var ledMeter = PlayerLEDMeter()

    init(identity: ControllerIdentity, hid: DualSenseInfo?, gc: GCController?,
         settings: ControllerSettings, waveform: HapticWaveform) {
        self.identity = identity
        self.hidInfo = hid
        self.gc = gc
        self.settings = settings
        self.waveform = waveform
        input = hid.map { DualSenseInput(device: $0.device) }
        refreshBattery()
    }

    // MARK: - 能力（决定界面显示哪些设置，D8）

    var isDualSense: Bool { identity.kind == .dualSense }
    var hasLight: Bool { isDualSense || gc?.light != nil }
    var hasAdaptiveTriggers: Bool { isDualSense }
    /// HD 震动只有 USB 的 DualSense 能用
    var hasHD: Bool { hidInfo.map { !$0.bluetooth } ?? false }
    var canVibrate: Bool { hidInfo != nil || gc?.haptics != nil }

    // 实际生效的开关 = 用户勾选 且 手柄支持
    var effVibration: Bool { settings.vibrationEnabled && canVibrate }
    var effTriggers: Bool { settings.triggersEnabled }
    var effLights: Bool { settings.lightEffects && hasLight }
    var allLeftToGame: Bool { !effVibration && !effTriggers && !effLights }

    /// 需要系统声音：跟随音乐，且震动或灯光由 App 控制
    var needsAudio: Bool {
        armed && settings.enabled && !allLeftToGame && settings.source == .music && (effVibration || effLights)
    }

    // MARK: - 显示

    var deviceName: String { isDualSense ? "DualSense" : (gc?.vendorName ?? "Controller") }

    var linkText: Bilingual? {
        if let hidInfo {
            return hidInfo.bluetooth ? Bilingual(zh: "蓝牙", en: "Bluetooth") : Bilingual(zh: "USB", en: "USB")
        }
        // 只有 GameController 能看到 DualSense：USB 时会出现它的音频设备，否则就是蓝牙；其他手柄不知道连接方式
        if isDualSense {
            return CA.dualSenseOutputDevice() != nil ? Bilingual(zh: "USB", en: "USB")
                                                    : Bilingual(zh: "蓝牙", en: "Bluetooth")
        }
        return nil
    }

    /// 下拉框里的名称：「DualSense · USB · 95%」
    var title: String {
        var parts = [deviceName]
        if let link = linkText { parts.append(link.text) }
        if let battery { parts.append("\(battery.level)%") }
        return parts.joined(separator: " · ")
    }

    func refreshBattery() {
        var value: (level: Int, charging: Bool)?
        if let s = input?.state {
            value = (s.batteryLevel, s.charging)
        } else if let b = gc?.battery, b.batteryState != .unknown || b.batteryLevel > 0 {
            value = (Int((b.batteryLevel * 100).rounded()), b.batteryState == .charging)
        }
        if battery?.level != value?.level || battery?.charging != value?.charging { battery = value }
    }

    func invalidateFeatures() { features.invalidate() }

    // MARK: - 设置变化

    private func settingsChanged(from old: ControllerSettings) {
        let new = settings
        if isActive {
            if new.triggersEnabled != old.triggersEnabled {
                hid?.controlsTriggers = effTriggers
                if hid == nil && !new.triggersEnabled && hasAdaptiveTriggers { features.setTriggerResistance(0) }
            }
            if new.lightEffects != old.lightEffects { hid?.controlsLights = effLights }
        }
        let restart = new.source != old.source || new.vibrationEnabled != old.vibrationEnabled
            || new.hdEnabled != old.hdEnabled
        let startStop = new.enabled != old.enabled || new.allLeftToGame != old.allLeftToGame
        if restart || startStop { reconcile(restart: restart && new.enabled == old.enabled) }
    }

    // MARK: - 开始 / 停止

    /// 全局开始：已启用的会话启动输出
    func arm() {
        armed = true
        reconcile(restart: false)
    }

    func disarm() {
        armed = false
        shutdown()
    }

    /// 手柄被拔掉：停止并释放
    func retire() {
        armed = false
        shutdown()
        input = nil
    }

    private func reconcile(restart: Bool) {
        let want = armed && settings.enabled && !allLeftToGame
        if want {
            if isActive {
                if restart { shutdown(); startOutputs() }
            } else {
                startOutputs()
            }
        } else if isActive {
            shutdown()
        }
    }

    /// 注册表发现这台手柄的连接状态变了（例如 USB ↔ 蓝牙）。只有连接方式真的变化才重启：
    /// 本 App 创建 / 销毁采集用的聚合设备也会触发设备变化通知，不能因此重启，否则会无限重启卡死主线程。
    func update(identity newIdentity: ControllerIdentity, hid newHID: DualSenseInfo?, gc newGC: GCController?) {
        let hidChanged: Bool
        switch (hidInfo, newHID) {
        case (nil, nil): hidChanged = false
        case let (a?, b?): hidChanged = !a.sameLink(as: b)
        default: hidChanged = true
        }
        let gcChanged = gc !== newGC
        let identityChanged = identity != newIdentity
        guard hidChanged || gcChanged || identityChanged else { return }

        identity = newIdentity
        if hidChanged {
            hidInfo = newHID
            input = newHID.map { DualSenseInput(device: $0.device) }
        }
        if gcChanged { gc = newGC }
        refreshBattery()
        let needsRestart = hidChanged || (gcChanged && (newHID == nil || !isDualSense))
        reconcile(restart: needsRestart)
    }

    private func startOutputs() {
        errorMessage = nil
        features.attach(gc)
        vibration.reset()
        lightShaper.reset()
        ledMeter = PlayerLEDMeter()
        massageTime = 0

        // 优先直接发 HID 报告（后台也能保持扳机阻尼/灯条）；打不开再退回 GameController
        if let info = hidInfo, let h = DualSenseHID.open(info) {
            hid = h
            output = h
            h.controlsRumble = effVibration
            h.controlsTriggers = effTriggers
            h.controlsLights = effLights
            // USB 时启用 HD 震动：音频第 3/4 声道驱动马达，HID 关掉兼容震动开关
            if effVibration, settings.hdEnabled, !info.bluetooth,
               let dev = CA.dualSenseOutputDevice(locationID: info.locationID),
               let out = try? HDHapticOutput(device: dev, waveform: waveform) {
                hd = out
                h.hdHaptics = true
            }
        } else if effVibration, let gc {
            do {
                output = try RumbleHapticOutput(controller: gc)
            } catch {
                let code = (error as NSError).code
                errorMessage = Bilingual(
                    zh: "系统的手柄震动服务连接失败（\(code)）。请拔插一次手柄；仍不行就在终端运行 sudo killall gamecontrollerd 重启该服务，然后重新点开始。",
                    en: "Could not connect to the system controller haptics service (\(code)). Reconnect the controller; if that fails, run sudo killall gamecontrollerd in Terminal and press Start again.")
            }
        }
        if settings.vibrationEnabled && !canVibrate {
            errorMessage = Bilingual(
                zh: "此模式不支持震动。8BitDo 请切到 S 模式（Switch 模式）后重新连接。",
                en: "Vibration is not supported in this mode. For 8BitDo, switch to S (Switch) mode and reconnect.")
        }
        engineName = !settings.vibrationEnabled ? Bilingual(zh: "震动交给游戏", en: "Vibration left to games")
                   : hd != nil ? Bilingual(zh: "HD 震动（USB）", en: "HD haptics (USB)")
                   : output?.name ?? Bilingual(zh: "震动不可用", en: "Vibration unavailable")
        NSLog("ControllerMusicVisualizer engine (%@): %@", identity.key, engineName.en)
        isActive = true
    }

    private func shutdown() {
        guard isActive else { return }
        hd?.stop()   // 先停音频波形，再让 HID 恢复兼容震动
        hd = nil
        output?.set(left: 0, right: 0)
        output?.stop()
        output = nil
        // 没有直连手柄时，扳机/灯光是通过 GameController 设置的，只重置由 App 控制的项
        if hid == nil {
            if effTriggers && hasAdaptiveTriggers { features.setTriggerResistance(0) }
            if effLights { features.reset() }
        }
        hid = nil
        isActive = false
        engineName = Bilingual(zh: "—", en: "—")
        level = (0, 0)
        randomNow = nil
    }

    // MARK: - 每 10ms 计算一次

    private var triggerReadings: (left: Float, right: Float) {
        if let s = input?.state { return (s.l2, s.r2) }
        return features.triggers
    }

    func tick(music: MusicFrame, dt: Float, count: Int) {
        guard isActive else { return }
        vibration.sensitivity = settings.sensitivity
        vibration.responsiveness = settings.responsiveness
        lightShaper.lightSpeed = settings.lightSpeed

        // 扳机（交给游戏时完全不碰）：阻尼；R2 加强度，L2 减强度，按得越深变得越快
        if effTriggers {
            if let hid {
                if hasAdaptiveTriggers { hid.setTriggerResistance(settings.triggerResistance) }
            } else {
                // 在后台时系统会重置扳机/灯条，每 0.5 秒补发一次
                if !NSApplication.shared.isActive && count % 50 == 0 { features.invalidate() }
                if hasAdaptiveTriggers { features.setTriggerResistance(settings.triggerResistance) }
            }
            let (lt, rt) = triggerReadings
            let dz: (Float) -> Float = { $0 < 0.05 ? 0 : $0 * $0 }
            let delta = (dz(rt) - dz(lt)) * 1.0 * dt
            if delta != 0 { settings.intensity = min(max(settings.intensity + delta, 0), 3) }
        }

        var l: Float, r: Float
        let lightLevel: (Float, Float), meterIn: (Float, Float)
        switch settings.source {
        case .music:
            (l, r) = vibration.update(music, mode: settings.musicMode, dt: dt)
            lightLevel = music.light
            meterIn = music.meter
        case .massage:
            massageTime += Double(dt) * settings.speed
            (l, r) = settings.preset.sample(massageTime)
            let now = settings.preset == .random ? settings.preset.current(massageTime) : nil
            if now != randomNow { randomNow = now }
            lightLevel = (l, r)   // 按摩时灯光直接跟随按摩波形
            meterIn = (l, r)
        }
        l = min(max(l * settings.intensity, 0), 1)
        r = min(max(r * settings.intensity, 0), 1)
        if !effVibration { l = 0; r = 0 }
        if let hd {
            let range = settings.source == .music ? settings.musicMode.carrierRange
                                                   : settings.preset.carrierRange(massageTime)
            hd.set(left: l, right: r, freq: hdFrequency(range, amplitude: max(l, r)),
                   useMusic: settings.source == .music)
            output?.set(left: 0, right: 0)   // HID 只负责扳机、灯光（并保持定期重发）
        } else {
            output?.set(left: l, right: r)   // 震动交给游戏时 HID 不设置马达强度，这里只为定期重发扳机、灯光
        }
        level = (l, r)

        // 灯光用强度之前的原始数值，强度调低也照样跳；交给游戏时完全不碰
        if effLights { updateLight(level: lightLevel, meter: meterIn, color: music.color, dt: dt) }
    }

    /// HD 载波频率随强度变化：震动弱时用高频（细腻），强时降到 50–65Hz（实测马达最有劲的区间）。
    /// 不低于 50Hz：再低马达反而没劲
    private func hdFrequency(_ range: (low: Float, high: Float), amplitude a: Float) -> Float {
        max(range.high - (range.high - range.low) * powf(a, 0.7), 50)
    }

    private func updateLight(level: (Float, Float), meter: (Float, Float),
                             color: (r: Float, g: Float, b: Float), dt: Float) {
        let r: Float, g: Float, b: Float
        switch settings.source {
        case .music:
            // 三色混合：低频红、中频绿、高频蓝，各自跟随能量（底鼓+人声=黄，人声+镲片=青，全部=白）
            let bar = lightShaper.update(level: level, color: color, dt: dt)
            let v = (1 - settings.lightRange) + settings.lightRange * bar.brightness
            (r, g, b) = (bar.color.r * v, bar.color.g * v, bar.color.b * v)
        case .massage:
            // 预设固定颜色，亮度跟随按摩波形
            let v = (1 - settings.lightRange) + settings.lightRange * (0.15 + 0.85 * max(level.0, level.1))
            (r, g, b) = hsv(settings.preset.hue(massageTime), 1, v)
        }
        if let hid {
            hid.setLight(r, g, b)
            hid.setPlayerLEDs(ledMeter.mask(left: meter.0, right: meter.1))
        } else {
            features.setLight(r, g, b)
        }
    }
}
