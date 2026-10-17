import Foundation

/// 每个手柄自己的震动整形：把分析器输出的原始特征，按这个手柄的「响应速度」「鼓点灵敏度」变成震动强度。
/// 分析器只做一份（所有手柄共用），这里的状态属于各自的会话。
public struct VibrationShaper {
    public var sensitivity: Float = 0.5     // 0...1，鼓点检测灵敏度
    public var responsiveness: Float = 0.7  // 0...1，震动跟随速度（尤其是声音变小时）

    private var beatAvg: Float = 0
    private var beatPulse: Float = 0
    private var sinceBeat: Float = 1
    private var bassSmooth: (Float, Float) = (0, 0)
    private var fullSmooth: (Float, Float) = (0, 0)

    public mutating func reset() { self = VibrationShaper(sensitivity: sensitivity, responsiveness: responsiveness) }

    /// 按响应速度在「柔和」和「灵敏」两端之间取时间常数（对数插值）
    private func tau(soft: Float, fast: Float) -> Float {
        soft * powf(fast / soft, responsiveness)
    }

    /// 快起、按响应速度回落的平滑。上升：15ms → 5ms；下降：250ms → 30ms
    private func follow(_ current: Float, _ target: Float, dt: Float) -> Float {
        let t = target > current ? tau(soft: 0.015, fast: 0.005) : tau(soft: 0.25, fast: 0.03)
        return current + (target - current) * (1 - expf(-dt / t))
    }

    /// dt = 距上次调用的时间（秒）。鼓点检测和两种平滑一直运行，切换模式时没有断档
    public mutating func update(_ f: MusicFrame, mode: MusicMode, dt: Float) -> (Float, Float) {
        // 鼓点检测：低音能量突然高于近期平均
        let mono = (f.bass.0 + f.bass.1) / 2
        let threshold = 2.2 - 1.2 * sensitivity          // 灵敏度 0 → 2.2 倍，1 → 1.0 倍
        let minLevel = 0.45 - 0.25 * sensitivity
        sinceBeat += dt
        if mono > beatAvg * threshold && mono > minLevel && sinceBeat > 0.12 {
            beatPulse = 1
            sinceBeat = 0
        }
        beatAvg += (mono - beatAvg) * (1 - expf(-dt / 0.4))
        beatPulse *= expf(-dt / tau(soft: 0.15, fast: 0.04))

        // 相对强度（不受歌曲本身音量影响），平方加大对比，再按响应速度平滑
        bassSmooth = (follow(bassSmooth.0, f.bassRelative.0 * f.bassRelative.0, dt: dt),
                      follow(bassSmooth.1, f.bassRelative.1 * f.bassRelative.1, dt: dt))
        fullSmooth = (follow(fullSmooth.0, f.fullRelative.0 * f.fullRelative.0, dt: dt),
                      follow(fullSmooth.1, f.fullRelative.1 * f.fullRelative.1, dt: dt))

        switch mode {
        case .beat:
            let maxB = max(f.bass.0, f.bass.1, 1e-3)
            return (beatPulse * f.bass.0 / maxB, beatPulse * f.bass.1 / maxB)
        case .bass: return bassSmooth
        case .envelope: return fullSmooth
        }
    }
}

/// 每个手柄自己的灯条整形：亮度按「灯条速度」平滑；颜色只在「暗 → 亮」的瞬间按当时的三频段混合选定，亮着时保持
public struct LightShaper {
    public var lightSpeed: Float = 0.3      // 0...1：0 像呼吸灯，1 干脆地一闪一闪

    private var lit = false
    private var barSmooth: Float = 0
    private var litTime: Float = 0
    private var falling = false
    private var latched: (Float, Float, Float) = (0, 0, 1)

    private static let darkThreshold: Float = 0.12   // 低于它算暗了
    private static let litThreshold: Float = 0.25    // 高于它算重新亮起（两个门槛防止在边缘来回换色）

    public mutating func reset() { self = LightShaper(lightSpeed: lightSpeed) }

    /// 灯条用：按「灯条速度」在 慢（起 20ms、落 300ms）和 快（起 3ms、落 60ms）之间取值
    private func followBar(_ current: Float, _ target: Float, dt: Float) -> Float {
        let rise = 0.02 * powf(0.15, lightSpeed), fall = 0.3 * powf(0.2, lightSpeed)
        let t = target > current ? rise : fall
        return current + (target - current) * (1 - expf(-dt / t))
    }

    /// level = 分析器的灯光亮度（左右），color = 三频段原始颜色。返回灯条亮度和已锁定的颜色（最亮通道 = 1）
    public mutating func update(level: (Float, Float), color: (r: Float, g: Float, b: Float), dt: Float)
        -> (brightness: Float, color: (r: Float, g: Float, b: Float)) {
        let previous = barSmooth
        barSmooth = followBar(barSmooth, max(level.0, level.1), dt: dt)
        let brightness = barSmooth

        func latch() {
            let m = max(color.r, color.g, color.b)
            if m > 1e-3 { latched = (color.r / m, color.g / m, color.b / m) }   // 归一到最亮 = 1
            litTime = 0
        }
        if lit {
            litTime += dt
            let trough = falling && brightness > previous   // 刚从下降转为上升 = 波谷
            if brightness < Self.darkThreshold {
                lit = false
            } else if litTime > 2, trough, brightness < 0.6 {
                latch()   // 慢速度下一直没暗透：连续亮 2 秒后，在下一个波谷换色
            }
        } else if brightness > Self.litThreshold {
            lit = true
            latch()
        }
        falling = brightness < previous
        return (brightness, (latched.0, latched.1, latched.2))
    }
}

/// 下方 5 颗白灯做成从中间向两边跳的立体声电平灯，跟随整体音量近似实时；
/// 只留约 80ms 的余晖防止在门槛边缘闪烁
public struct PlayerLEDMeter {
    private var hold: (Float, Float) = (0, 0)

    public mutating func mask(left: Float, right: Float) -> UInt8 {
        let fall: Float = 0.12   // 每 10ms 最多下降 0.12
        hold.0 = max(left, hold.0 - fall)
        hold.1 = max(right, hold.1 - fall)
        var mask: UInt8 = 0
        if max(hold.0, hold.1) > 0.15 { mask |= 0b00100 }   // 中间
        if hold.0 > 0.45 { mask |= 0b00010 }
        if hold.0 > 0.8 { mask |= 0b00001 }
        if hold.1 > 0.45 { mask |= 0b01000 }
        if hold.1 > 0.8 { mask |= 0b10000 }
        return mask
    }
}

/// HSV → RGB，h/s/v 都是 0...1
public func hsv(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
    let h6 = (h - floorf(h)) * 6
    let i = Int(h6) % 6, f = h6 - floorf(h6)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}
