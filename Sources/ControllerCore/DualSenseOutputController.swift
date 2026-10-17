import Foundation

/// DualSense 输出报告的状态机（与平台无关）：震动、扳机阻尼、灯条、白灯、HD 模式、扬声器通路合在一份报告里。
///
/// 规则（从 macOS 版 DualSenseHID 原样抽出）：
/// - 各项由 App 控制还是交给游戏。交给游戏的项不设置「生效」标志位，手柄保留游戏的设置；
///   全部交给游戏时完全不发报告。
/// - 手柄会一直保留最后收到的设置，所以交出去的那一刻先发一次「恢复默认」再放手。
/// - 状态没变化时也每 0.1 秒重发一次，盖掉系统在切换前后台时发出的重置。
/// - 蓝牙报告带 4 位序号。
///
/// 真正的发送由平台注入（macOS：IOHIDDeviceSetReport；Windows：WriteFile；Android：HidDevice.sendOutputReport）。
public final class DualSenseOutputController {
    /// 发送一份完整报告（含报告 ID）；返回是否成功
    public typealias Sink = (_ report: [UInt8]) -> Bool

    public let bluetooth: Bool
    private let sink: Sink
    private let clock: () -> Double

    /// HD 震动模式：关掉兼容震动开关，手柄改由 USB 音频第 3/4 声道的波形驱动（只有 USB 可用）
    public var hdHaptics = false { didSet { if hdHaptics != oldValue { dirty = true } } }

    public var controlsRumble = true {
        didSet { if controlsRumble != oldValue { releaseRumble = !controlsRumble; handedOver() } }
    }
    public var controlsTriggers = true {
        didSet { if controlsTriggers != oldValue { releaseTriggers = !controlsTriggers; handedOver() } }
    }
    public var controlsLights = true {
        didSet { if controlsLights != oldValue { releaseLights = !controlsLights; handedOver() } }
    }
    private var releaseRumble = false, releaseTriggers = false, releaseLights = false

    /// 扬声器通路：打开后路径固定为 3（耳机静音，扬声器 ← 右声道）；关闭 / 停止时发一次路径 0 再放手
    private var speakerOn = false
    private var speakerVolume: UInt8 = 0x64, speakerPreamp: UInt8 = 0
    private var releaseSpeaker = false

    private var seq: UInt8 = 0
    private var motorLeft: UInt8 = 0
    private var motorRight: UInt8 = 0
    private var resistance: UInt8 = 0
    private var light: (UInt8, UInt8, UInt8) = (0, 64, 255)
    private var playerLEDs: UInt8 = 0b00100   // 默认只亮中间一颗
    private var dirty = true
    private var lastSent = -Double.infinity

    /// 状态不变时也定期重发，盖掉系统在切换前后台时发出的重置
    public static let keepAlive: Double = 0.1

    /// clock：单调递增的秒数（测试里可以注入假时钟）
    public init(bluetooth: Bool, clock: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate },
                sink: @escaping Sink) {
        self.bluetooth = bluetooth
        self.clock = clock
        self.sink = sink
    }

    // MARK: - 输入

    /// 兼容震动：左 = 重马达，右 = 轻马达。每 10ms 调用一次，顺便负责定期重发
    public func set(left: Float, right: Float) {
        let l = Self.byte(left), r = Self.byte(right)
        if l != motorLeft || r != motorRight {
            motorLeft = l; motorRight = r; dirty = true
        }
        flush()
    }

    /// 0 = 关闭，1 = 最硬
    public func setTriggerResistance(_ strength: Float) {
        let v = Self.byte(strength)
        if v != resistance { resistance = v; dirty = true }
    }

    public func setLight(_ r: Float, _ g: Float, _ b: Float) {
        let c = (Self.byte(r), Self.byte(g), Self.byte(b))
        if c != light { light = c; dirty = true }
    }

    /// 下方 5 颗白灯，bit0…bit4 从左到右
    public func setPlayerLEDs(_ mask: UInt8) {
        let m = mask & 0x1F
        if m != playerLEDs { playerLEDs = m; dirty = true }
    }

    public func setSpeaker(_ on: Bool, hwVolume: UInt8 = 0x64, preamp: UInt8 = 0) {
        if on == speakerOn && (!on || (hwVolume == speakerVolume && preamp == speakerPreamp)) { return }
        if !on && speakerOn { releaseSpeaker = true }
        speakerOn = on
        speakerVolume = hwVolume; speakerPreamp = preamp
        handedOver()
    }

    /// 停止：所有由 App 控制的项恢复默认（马达 0、扳机关、灯条默认蓝、兼容震动、扬声器静音），发最后一次
    public func stop() {
        motorLeft = 0; motorRight = 0; resistance = 0
        light = (0, 64, 255)
        hdHaptics = false
        playerLEDs = 0b00100
        if speakerOn { speakerOn = false; releaseSpeaker = true }
        _ = send()
    }

    // MARK: - 发送

    /// 控制权变化后立即发送（交出的项这一次会发默认值）
    private func handedOver() {
        dirty = true
        flush()
    }

    private func flush() {
        if dirty || clock() - lastSent > Self.keepAlive { _ = send() }
    }

    /// 当前状态对应的报告（交出去的项已替换成默认值）。全部交给游戏时为 nil
    private func makeReport() -> [UInt8]? {
        let rumble = controlsRumble || releaseRumble
        let triggers = controlsTriggers || releaseTriggers
        let lights = controlsLights || releaseLights
        let speakerTouched = speakerOn || releaseSpeaker
        guard rumble || triggers || lights || speakerTouched else { return nil }

        var motors = (motorLeft, motorRight), resist = resistance, rgb = light, leds = playerLEDs
        var hd = hdHaptics
        if releaseRumble { motors = (0, 0); hd = false }
        if releaseTriggers { resist = 0 }
        if releaseLights { rgb = (0, 64, 255); leds = 0b00100 }
        releaseRumble = false; releaseTriggers = false; releaseLights = false

        let state = DualSenseOutputState(rumble: rumble, triggers: triggers, lights: lights, hd: hd,
                                         motorLeft: motors.0, motorRight: motors.1, resistance: resist,
                                         rgb: rgb, playerLEDs: leds,
                                         speaker: speakerOn ? .on(volume: speakerVolume, preamp: speakerPreamp)
                                                            : (releaseSpeaker ? .off : .untouched))
        releaseSpeaker = false
        let report = DualSenseReport.make(state, bluetooth: bluetooth, seq: seq)
        if bluetooth { seq = (seq + 1) & 0x0F }
        return report
    }

    /// 立即发送一次（打开设备后的第一份报告也用它）。全部交给游戏时不发、视为成功
    @discardableResult
    public func send() -> Bool {
        guard let report = makeReport() else { return true }
        let ok = sink(report)
        dirty = false
        lastSent = clock()
        return ok
    }

    static func byte(_ v: Float) -> UInt8 { UInt8(clamping: Int((min(max(v, 0), 1) * 255).rounded())) }
}
