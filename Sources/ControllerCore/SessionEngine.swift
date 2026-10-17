import Foundation

/// 一个手柄会话每个 tick 的「生效开关」：用户勾选 且 手柄支持、且输出通道确实打开了
public struct SessionFlags: Equatable, Sendable {
    public var vibration: Bool          // App 控制震动
    public var triggers: Bool           // App 控制扳机（阻尼 + L2/R2 调强度）
    public var lights: Bool             // App 控制灯光
    public var adaptiveTriggers: Bool   // 手柄有自适应扳机（发阻尼）
    public var playerLEDs: Bool         // 有白灯可用（DualSense 直连 HID 时）
    public var hdActive: Bool           // HD 音频输出正在运行

    public init(vibration: Bool, triggers: Bool, lights: Bool, adaptiveTriggers: Bool,
                playerLEDs: Bool, hdActive: Bool) {
        self.vibration = vibration; self.triggers = triggers; self.lights = lights
        self.adaptiveTriggers = adaptiveTriggers; self.playerLEDs = playerLEDs; self.hdActive = hdActive
    }
}

public struct SessionTickInput {
    public var settings: ControllerSettings
    public var flags: SessionFlags
    public var music: MusicFrame
    /// 两个扳机的按压深度 0...1
    public var triggers: (left: Float, right: Float)
    public var dt: Float
    /// 震动相对扬声器 / HD 载波的对齐延迟（毫秒，平台按设备延迟算出；0 = 不延迟）
    public var alignDelayMs: Double

    public init(settings: ControllerSettings, flags: SessionFlags, music: MusicFrame,
                triggers: (left: Float, right: Float), dt: Float, alignDelayMs: Double) {
        self.settings = settings; self.flags = flags; self.music = music
        self.triggers = triggers; self.dt = dt; self.alignDelayMs = alignDelayMs
    }
}

public struct HDCommand: Equatable, Sendable {
    public var left: Float, right: Float, freq: Float, useMusic: Bool
    public init(left: Float, right: Float, freq: Float, useMusic: Bool) {
        self.left = left; self.right = right; self.freq = freq; self.useMusic = useMusic
    }
}

/// 一个 tick 的输出：平台照做即可
public struct SessionCommands {
    /// L2/R2 改了强度：写回设置
    public var intensity: Float?
    /// 扳机阻尼（App 控制扳机且手柄有自适应扳机时）
    public var triggerResistance: Float?
    /// 兼容震动的马达强度（HD 运行时为 0；每个 tick 都要发，顺便定期重发扳机 / 灯光）
    public var motors: (left: Float, right: Float) = (0, 0)
    /// HD 震动（HD 输出运行时）
    public var hd: HDCommand?
    /// 灯条颜色（App 控制灯光时）
    public var light: (r: Float, g: Float, b: Float)?
    /// 白灯（有白灯且 App 控制灯光时）
    public var playerLEDs: UInt8?
    /// 界面电平（强度之后、对齐之前）
    public var level: (left: Float, right: Float) = (0, 0)
    /// 随机按摩当前轮播到的预设
    public var randomNow: MassagePreset?
}

/// 一个手柄会话每 10ms 的计算（与平台无关）：扳机调强度、跟随音乐 / 按摩的震动、
/// 震动与扬声器的对齐、HD 载波频率、灯条和白灯。逻辑与 macOS 版原来的 `ControllerSession.tick` 一致。
public struct SessionEngine {
    private var vibration = VibrationShaper()
    private var lightShaper = LightShaper()
    private var ledMeter = PlayerLEDMeter()
    private var align = DelayLine()
    private var alignClock = 0.0
    private var massageTime: Double = 0

    public init() {}

    /// 输出通道（重新）启动时调用
    public mutating func reset() {
        vibration.reset()
        lightShaper.reset()
        ledMeter = PlayerLEDMeter()
        align.reset()
        alignClock = 0
        massageTime = 0
    }

    public mutating func tick(_ input: SessionTickInput) -> SessionCommands {
        let settings = input.settings, flags = input.flags, music = input.music, dt = input.dt
        var out = SessionCommands()
        vibration.sensitivity = settings.sensitivity
        vibration.responsiveness = settings.responsiveness
        lightShaper.lightSpeed = settings.lightSpeed

        // 扳机（交给游戏时完全不碰）：阻尼；R2 加强度，L2 减强度，按得越深变得越快
        var intensity = settings.intensity
        if flags.triggers {
            if flags.adaptiveTriggers { out.triggerResistance = settings.triggerResistance }
            let (lt, rt) = input.triggers
            let dz: (Float) -> Float = { $0 < 0.05 ? 0 : $0 * $0 }
            let delta = (dz(rt) - dz(lt)) * 1.0 * dt
            if delta != 0 {
                intensity = min(max(intensity + delta, 0), 3)
                out.intensity = intensity
            }
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
            out.randomNow = settings.preset == .random ? settings.preset.current(massageTime) : nil
            lightLevel = (l, r)   // 按摩时灯光直接跟随按摩波形
            meterIn = (l, r)
        }
        l = min(max(l * intensity, 0), 1)
        r = min(max(r * intensity, 0), 1)
        if !flags.vibration { l = 0; r = 0 }
        out.level = (l, r)

        // 对齐：较快的一路加一点延迟（HD 的强度包络早于缓冲里的载波；兼容震动早于扬声器）
        alignClock += Double(dt)
        if input.alignDelayMs > 0 {
            align.push(time: alignClock, l, r)
            (l, r) = align.value(at: alignClock - input.alignDelayMs / 1000)
        }
        if flags.hdActive {
            let range = settings.source == .music ? settings.musicMode.carrierRange
                                                   : settings.preset.carrierRange(massageTime)
            out.hd = HDCommand(left: l, right: r, freq: Self.hdFrequency(range, amplitude: max(l, r)),
                               useMusic: settings.source == .music)
            out.motors = (0, 0)   // HID 只负责扳机、灯光（并保持定期重发）
        } else {
            out.motors = (l, r)   // 震动交给游戏时 HID 不设置马达强度，这里只为定期重发扳机、灯光
        }

        // 灯光用强度之前的原始数值，强度调低也照样跳；交给游戏时完全不碰
        if flags.lights {
            out.light = light(settings, level: lightLevel, color: music.color, dt: dt)
            if flags.playerLEDs { out.playerLEDs = ledMeter.mask(left: meterIn.0, right: meterIn.1) }
        }
        return out
    }

    /// HD 载波频率随强度变化：震动弱时用高频（细腻），强时降到 50–65Hz（实测马达最有劲的区间）。
    /// 不低于 50Hz：再低马达反而没劲
    public static func hdFrequency(_ range: (low: Float, high: Float), amplitude a: Float) -> Float {
        max(range.high - (range.high - range.low) * powf(a, 0.7), 50)
    }

    private mutating func light(_ settings: ControllerSettings, level: (Float, Float),
                                color: (r: Float, g: Float, b: Float), dt: Float) -> (r: Float, g: Float, b: Float) {
        switch settings.source {
        case .music:
            // 三色混合：低频红、中频绿、高频蓝，各自跟随能量（底鼓+人声=黄，人声+镲片=青，全部=白）
            let bar = lightShaper.update(level: level, color: color, dt: dt)
            let v = (1 - settings.lightRange) + settings.lightRange * bar.brightness
            return (bar.color.r * v, bar.color.g * v, bar.color.b * v)
        case .massage:
            // 预设固定颜色，亮度跟随按摩波形
            let v = (1 - settings.lightRange) + settings.lightRange * (0.15 + 0.85 * max(level.0, level.1))
            let c = hsv(settings.preset.hue(massageTime), 1, v)
            return (c.0, c.1, c.2)
        }
    }
}
