import AppKit
import ControllerCore
import CoreAudio
import Foundation
import GameController

/// 一个手柄的运行时（macOS 底层）：持有它自己的设置、输出通道和电平。
/// 每 10ms 的计算（震动、扳机、灯光、对齐）在 ControllerCore 的 `SessionEngine` 里，这里只负责设备。
/// 由 `AppModel` 的 100Hz 主循环依次调用 `tick`；界面看不到这个类型，只看到 `info` 快照。
@MainActor
final class ControllerSession {
    /// 会话的稳定编号；手柄换了连接方式（USB ↔ 蓝牙）时编号不变
    let id: ControllerID = UUID().uuidString
    private(set) var identity: ControllerIdentity

    /// 引擎持有的设置（唯一真源）；界面通过 `apply(_:)` 改
    private(set) var settings: ControllerSettings
    private(set) var hidInfo: DualSenseInfo?
    private(set) var gc: GCController?

    /// 输出通道是否在运行
    private(set) var isActive = false { didSet { if isActive != oldValue { changed() } } }
    private(set) var battery: Battery? { didSet { if battery != oldValue { changed() } } }
    private(set) var engineName = Bilingual(zh: "—", en: "—") { didSet { if engineName != oldValue { changed() } } }
    /// 界面电平（强度之后、对齐之前）
    private(set) var level: (Float, Float) = (0, 0)
    /// 随机按摩当前轮播到的预设
    private(set) var randomNow: MassagePreset? { didSet { if randomNow != oldValue { changed() } } }
    private(set) var errorMessage: Bilingual? { didSet { if errorMessage != oldValue { changed() } } }
    /// 手柄扬声器相对 Mac 音响的延迟分解（扬声器同步播放运行时才有）
    private(set) var latency: LatencyBreakdown? { didSet { if latency != oldValue { changed() } } }
    /// 调试信息：IO 缓冲帧数、环形缓冲余量、欠载次数
    private(set) var audioStats: String? { didSet { if audioStats != oldValue { changed() } } }

    /// 快照里的任何数值变了（AppModel 据此重发状态）
    var onChange: () -> Void = {}
    /// 设置变了（AppModel 据此保存、重新判断是否需要采集系统声音）
    var onSettingsChange: () -> Void = {}
    private func changed() { onChange() }

    /// 全局「开始」是否按下
    private(set) var armed = false

    private let waveform: HapticWaveform
    private let features = ControllerFeatures()
    private var input: DualSenseInput?
    private var output: HapticOutput?
    private var hid: DualSenseHID?
    private var audio: DualSenseAudioOutput?
    private var hdActive = false
    private let feed: SpeakerFeed
    private let tuning: SpeakerTuning
    /// 系统声音采集（tap 聚合设备）的延迟数值；采集还没起来时为 nil
    private let tapTiming: () -> DeviceTiming?
    private var controllerTiming = DeviceTiming()
    // 震动与扬声器的对齐：较快的一路加一点延迟（见 LatencyModel）
    private var alignDelayMs = 0.0
    private var engine = SessionEngine()

    init(identity: ControllerIdentity, hid: DualSenseInfo?, gc: GCController?,
         settings: ControllerSettings, waveform: HapticWaveform, feed: SpeakerFeed,
         tuning: SpeakerTuning, tapTiming: @escaping () -> DeviceTiming?) {
        self.identity = identity
        self.hidInfo = hid
        self.gc = gc
        self.settings = settings
        self.waveform = waveform
        self.feed = feed
        self.tuning = tuning
        self.tapTiming = tapTiming
        input = hid.map { DualSenseInput(device: $0.device) }
        refreshBattery()
    }

    // MARK: - 能力（决定界面显示哪些设置，D8）

    var isDualSense: Bool { identity.kind == .dualSense }
    var hasLight: Bool { isDualSense || gc?.light != nil }
    var hasAdaptiveTriggers: Bool { isDualSense }
    /// HD 震动只有 USB 的 DualSense 能用
    var hasHD: Bool { hidInfo.map { !$0.bluetooth } ?? false }
    /// 手柄扬声器同步播放：同样只有 USB 的 DualSense 能用（蓝牙下声音走私有的压缩报告，不支持）
    var hasSpeaker: Bool { hasHD }
    var canVibrate: Bool { hidInfo != nil || gc?.haptics != nil }

    // 实际生效的开关 = 用户勾选 且 手柄支持
    var effVibration: Bool { settings.vibrationEnabled && canVibrate }
    var effTriggers: Bool { settings.triggersEnabled }
    var effLights: Bool { settings.lightEffects && hasLight }
    var effSpeaker: Bool { settings.speakerEnabled && hasSpeaker }
    var allLeftToGame: Bool { !effVibration && !effTriggers && !effLights && !effSpeaker }

    /// 需要系统声音：扬声器同步播放（任何模式），或跟随音乐且震动或灯光由 App 控制
    var needsAudio: Bool {
        armed && settings.enabled && !allLeftToGame
            && (effSpeaker || (settings.source == .music && (effVibration || effLights)))
    }

    // MARK: - 显示

    var deviceName: String { isDualSense ? "DualSense" : (gc?.vendorName ?? "Controller") }

    var link: LinkKind? {
        if let hidInfo { return hidInfo.bluetooth ? .bluetooth : .usb }
        // 只有 GameController 能看到 DualSense：USB 时会出现它的音频设备，否则就是蓝牙；其他手柄不知道连接方式
        if isDualSense { return CA.dualSenseOutputDevice() != nil ? .usb : .bluetooth }
        return nil
    }

    /// 给界面的快照
    var info: ControllerInfo {
        ControllerInfo(
            id: id, name: deviceName, link: link, battery: battery,
            capabilities: Capabilities(isDualSense: isDualSense, hasLight: hasLight,
                                       hasAdaptiveTriggers: hasAdaptiveTriggers, hasHD: hasHD,
                                       hasSpeaker: hasSpeaker, canVibrate: canVibrate),
            settings: settings,
            status: SessionStatus(isActive: isActive, engineName: engineName, error: errorMessage),
            latency: latency, audioStats: audioStats, randomNow: randomNow)
    }

    func refreshBattery() {
        var value: Battery?
        if let s = input?.state {
            value = Battery(level: s.batteryLevel, charging: s.charging)
        } else if let b = gc?.battery, b.batteryState != .unknown || b.batteryLevel > 0 {
            value = Battery(level: Int((b.batteryLevel * 100).rounded()), charging: b.batteryState == .charging)
        }
        battery = value
    }

    func invalidateFeatures() { features.invalidate() }

    // MARK: - 设置变化

    /// 改设置（只改补丁里给出的字段）
    func apply(_ patch: SettingsPatch) {
        let old = settings
        let new = patch.apply(to: old)
        guard new != old else { return }
        settings = new
        settingsChanged(from: old)
        changed()
        onSettingsChange()
    }

    private func settingsChanged(from old: ControllerSettings) {
        let new = settings
        if isActive {
            if new.triggersEnabled != old.triggersEnabled {
                hid?.controlsTriggers = effTriggers
                if hid == nil && !new.triggersEnabled && hasAdaptiveTriggers { features.setTriggerResistance(0) }
            }
            if new.lightEffects != old.lightEffects { hid?.controlsLights = effLights }
            if new.speakerVolume != old.speakerVolume { applySpeaker() }
        }
        let restart = new.source != old.source || new.vibrationEnabled != old.vibrationEnabled
            || new.hdEnabled != old.hdEnabled || new.speakerEnabled != old.speakerEnabled
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
        engine.reset()

        // 优先直接发 HID 报告（后台也能保持扳机阻尼/灯条）；打不开再退回 GameController
        if let info = hidInfo, let h = DualSenseHID.open(info) {
            hid = h
            output = h
            h.controlsRumble = effVibration
            h.controlsTriggers = effTriggers
            h.controlsLights = effLights
            // USB 时用手柄的音频设备：第 3/4 声道 = HD 震动（HID 关掉兼容震动开关），第 1/2 声道 = 扬声器
            let wantHD = effVibration && settings.hdEnabled && !info.bluetooth
            let wantSpeaker = effSpeaker
            if wantHD || wantSpeaker {
                if let dev = CA.dualSenseOutputDevice(locationID: info.locationID),
                   let out = try? DualSenseAudioOutput(device: dev, waveform: waveform, feed: feed,
                                                       haptics: wantHD, tuning: tuning) {
                    audio = out
                    controllerTiming = CA.timing(dev, scope: kAudioObjectPropertyScopeOutput)
                    if wantHD { h.hdHaptics = true; hdActive = true }
                    if wantSpeaker { applySpeaker() }
                } else if wantSpeaker {
                    errorMessage = Bilingual(zh: "无法打开手柄的音频设备，扬声器同步播放不可用。",
                                             en: "Could not open the controller's audio device; speaker playback is unavailable.")
                }
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
                   : hdActive ? Bilingual(zh: "HD 震动（USB）", en: "HD haptics (USB)")
                   : output?.name ?? Bilingual(zh: "震动不可用", en: "Vibration unavailable")
        if audio != nil && effSpeaker {
            engineName = Bilingual(zh: engineName.zh + " + 手柄扬声器", en: engineName.en + " + speaker")
        }
        updateAlignment()
        refreshLatency()
        NSLog("ControllerMusicVisualizer engine (%@): %@", identity.key, engineName.en)
        isActive = true
    }

    private func shutdown() {
        guard isActive else { return }
        audio?.stop()   // 先停音频（扬声器淡出、停波形），再让 HID 恢复兼容震动、关掉扬声器通路
        audio = nil
        hdActive = false
        latency = nil
        audioStats = nil
        alignDelayMs = 0
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
        if let s = input?.freshState { return (s.l2, s.r2) }
        return features.triggers   // 收不到 HID 输入报告（例如没有输入监控权限）时用 GameController
    }

    func tick(music: MusicFrame, dt: Float, count: Int) {
        guard isActive else { return }
        if count % 50 == 0 { updateAlignment() }
        // 没有直连手柄时扳机 / 灯条走 GameController：在后台时系统会重置它们，每 0.5 秒补发一次
        if hid == nil && effTriggers && !NSApplication.shared.isActive && count % 50 == 0 {
            features.invalidate()
        }

        let flags = SessionFlags(vibration: effVibration, triggers: effTriggers, lights: effLights,
                                 adaptiveTriggers: hasAdaptiveTriggers, playerLEDs: hid != nil,
                                 hdActive: hdActive && audio != nil)
        let c = engine.tick(SessionTickInput(settings: settings, flags: flags, music: music,
                                             triggers: triggerReadings, dt: dt, alignDelayMs: alignDelayMs))

        if let v = c.triggerResistance {
            if let hid { hid.setTriggerResistance(v) } else { features.setTriggerResistance(v) }
        }
        if let v = c.intensity {
            // L2 / R2 改的强度也是设置：写回并通知界面（AppModel 节流后才重发状态）
            settings.intensity = v
            changed()
            onSettingsChange()
        }
        level = c.level
        randomNow = c.randomNow
        if let hd = c.hd { audio?.set(left: hd.left, right: hd.right, freq: hd.freq, useMusic: hd.useMusic) }
        output?.set(left: c.motors.left, right: c.motors.right)
        if let light = c.light {
            if let hid {
                hid.setLight(light.r, light.g, light.b)
                if let leds = c.playerLEDs { hid.setPlayerLEDs(leds) }
            } else {
                features.setLight(light.r, light.g, light.b)
            }
        }
    }

    // MARK: - 扬声器与对齐

    /// 打开扬声器通路（路径 3 + 硬件音量）并设置软件音量。音量 0 时通路保持打开、软件增益为 0（静音，无需反复开关）
    private func applySpeaker() {
        guard effSpeaker, let hid, let audio else { return }
        hid.setSpeaker(true, hwVolume: tuning.hwVolume, preamp: tuning.preamp)
        audio.setSpeakerGain(SpeakerVolume.gain(settings.speakerVolume))
    }

    /// 重新计算震动相对扬声器 / 载波的对齐延迟（缓冲余量会自适应变化，所以定期更新）
    private func updateAlignment() {
        guard let audio, settings.source == .music else { alignDelayMs = 0; return }
        let margin = audio.marginMs
        if hdActive {
            alignDelayMs = LatencyModel.hdEnvelopeDelayMs(marginMs: margin)
        } else if effSpeaker {
            alignDelayMs = max(tuning.hapticsDelayMs ?? LatencyModel.compatHapticDelayMs(
                marginMs: margin, controllerOutputMs: controllerTiming.ms), 0)
        } else {
            alignDelayMs = 0
        }
    }

    /// 估算手柄扬声器相对 Mac 音响的延迟，并刷新调试信息
    func refreshLatency() {
        guard let audio, effSpeaker else { return }
        let tapT = tapTiming()
        let defaultOut = CA.defaultOutputDevice()
        let macT = defaultOut != kAudioObjectUnknown ? CA.timing(defaultOut, scope: kAudioObjectPropertyScopeOutput) : nil
        let margin = audio.marginMs > 0 ? audio.marginMs
            : LatencyModel.minMarginMs(chunkFrames: tapT?.bufferFrames ?? 512,
                                       outBlockFrames: Double(audio.ioFrames), sampleRate: controllerTiming.sampleRate)
        if let tapT {
            let b = LatencyModel.breakdown(tapInput: tapT, marginMs: margin, controller: controllerTiming, macOutput: macT)
            if b != latency { latency = b }
        }
        audioStats = String(format: "IO %d frames · margin %.1f ms · underruns %d · align %.0f ms",
                            audio.ioFrames, margin, audio.underruns, alignDelayMs)
    }
}
