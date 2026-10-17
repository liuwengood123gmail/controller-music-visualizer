import Foundation

// 手柄扬声器同步播放的纯逻辑部分（无系统依赖，可单元测试）。设计见 docs/controller-speaker-design.md

/// 二阶 Butterworth 高通（RBJ 公式，直接 II 型转置）
public struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    public static func highpass(hz: Float, sampleRate: Float) -> Biquad {
        var f = Biquad()
        let w0 = 2 * Float.pi * min(hz, sampleRate * 0.45) / sampleRate
        let alpha = sinf(w0) / (2 * 0.70710678)
        let c = cosf(w0)
        let a0 = 1 + alpha
        f.b0 = (1 + c) / 2 / a0
        f.b1 = -(1 + c) / a0
        f.b2 = f.b0
        f.a1 = -2 * c / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

public enum SpeakerVolume {
    /// 滑块 0...1 → 线性增益：按分贝线性映射，0 = 完全静音，接近 0 = minDb，1 = maxDb。
    /// 手柄扬声器很小，原样播放太轻：100% 允许放大到 +18dB，超出部分由软限幅平滑压住（声音更「满」，不爆音）
    public static let minDb: Float = -24
    public static let maxDb: Float = 18
    public static let defaultVolume: Float = 0.3

    public static func gain(_ v: Float) -> Float {
        guard v > 0.001 else { return 0 }
        return powf(10, (minDb + (maxDb - minDb) * min(v, 1)) / 20)
    }
}

public enum SoftLimiter {
    /// tanh 软限幅：小信号几乎不变，大信号平滑压到 ±1，不会爆音
    @inline(__always)
    public static func process(_ x: Float) -> Float { tanhf(x) }
}

/// 一阶平滑增益：开 / 关 / 拖动音量时 10–20ms 内渐变，避免咔哒声
public struct GainRamp {
    private(set) var value: Float = 0
    /// time = 时间常数（秒）；约 4 个时间常数后到位（4ms → 约 16–20ms）
    @inline(__always)
    public mutating func step(target: Float, k: Float) -> Float {
        value += (target - value) * k
        return value
    }
    public static func coefficient(sampleRate: Float, tau: Float = 0.004) -> Float { 1 - expf(-1 / (tau * sampleRate)) }

    public init() {}
}

/// 读位置游标：写端（采集线程）按块写入，读端（设备渲染线程）按自己的时钟读。
/// 两边是不同设备、时钟各自独立：
/// - 读位置与写位置的距离（lag）长期稳定在目标值附近：用平滑后的 lag 误差微调读取步长（±0.5%，听不出音高变化），
///   这样不会因为时钟漂移每隔几十秒就硬重同步一次（会咔哒）
/// - 欠载（lag 不够读一块）或严重积压时硬重同步，并计数
public struct RingCursor {
    public var readPos: Double = 0
    private var started = false
    private var lagAvg: Double = 0
    private(set) var underruns = 0
    private(set) var overruns = 0

    public mutating func stall() { started = false }

    /// 返回本块读取步长（源采样帧 / 输出帧）。written = 已写入的源采样总数；
    /// target = 目标 lag（源采样帧）；blockSeconds = 本块时长
    public mutating func prepare(written: Double, frames n: Int, nominalStep: Double,
                          target: Double, blockSeconds: Double) -> Double {
        let lag = written - readPos
        if !started {
            started = true
            resync(written, target)
            return nominalStep
        }
        if lag < Double(n) * nominalStep {
            underruns += 1
            resync(written, target)
            return nominalStep
        }
        if lag > target * 3 + Double(n) * nominalStep {
            overruns += 1
            resync(written, target)
            return nominalStep
        }
        lagAvg += (lag - lagAvg) * min(blockSeconds / 0.3, 1)
        let err = (lagAvg - target) / max(target, 1)
        return nominalStep * (1 + min(max(err * 0.02, -0.005), 0.005))
    }

    private mutating func resync(_ written: Double, _ target: Double) {
        readPos = max(written - target, 0)
        lagAvg = target
    }

    public init() {}
}

/// 环形缓冲余量自适应：以 floor 为底，每发生一次欠载就多留 2ms（最多 20ms），
/// 长时间（30 秒）稳定后每次收回 1ms，自动落在「不欠载的最小值」附近
public struct AdaptiveMargin {
    private(set) var extraMs: Double = 0
    private var quiet: Double = 0

    public mutating func update(underrun: Bool, dt: Double) {
        if underrun {
            extraMs = min(extraMs + 2, 20)
            quiet = 0
        } else {
            quiet += dt
            if quiet > 30 {
                extraMs = max(extraMs - 1, 0)
                quiet = 0
            }
        }
    }

    public init() {}
}

/// 带时间戳的延迟线（线性插值）：给较快的一路震动加固定延迟，使它与扬声器对齐
public struct DelayLine {
    private var times: [Double] = Array(repeating: -.infinity, count: 128)
    private var lefts: [Float] = Array(repeating: 0, count: 128)
    private var rights: [Float] = Array(repeating: 0, count: 128)
    private var head = 0   // 下一个写入位置

    public mutating func push(time: Double, _ l: Float, _ r: Float) {
        times[head] = time; lefts[head] = l; rights[head] = r
        head = (head + 1) % times.count
    }

    public mutating func reset() {
        for i in times.indices { times[i] = -.infinity }
        head = 0
    }

    /// t 时刻的值：在相邻两条记录之间线性插值；早于最旧记录返回最旧的，晚于最新的返回最新的
    public func value(at t: Double) -> (Float, Float) {
        let n = times.count
        var newer: Int?
        for k in 1...n {
            let i = (head - k + n) % n
            guard times[i] > -.infinity else { break }
            if times[i] <= t {
                guard let j = newer, times[j] > times[i] else { return (lefts[i], rights[i]) }
                let f = Float((t - times[i]) / (times[j] - times[i]))
                return (lefts[i] + (lefts[j] - lefts[i]) * f, rights[i] + (rights[j] - rights[i]) * f)
            }
            newer = i
        }
        // 比所有记录都早：用最旧的一条
        if let j = newer { return (lefts[j], rights[j]) }
        return (0, 0)
    }

    public init() {}
}

/// 扬声器要播放的声音：单声道混合 → 200Hz 高通 → 环形缓冲（所有手柄共享一份，每个输出有自己的读位置）。
/// 采集线程写、各手柄的渲染线程读（单写单读）。音量、限幅、淡入淡出在读端（各手柄独立）。
public final class SpeakerFeed {
    public static let size = 1 << 14
    public static let mask = size - 1

    public let buffer: UnsafeMutablePointer<Float>
    /// 已写入的样本总数（与 HapticWaveform.written 同步推进：两者在同一个采集回调里各写 frames 个）
    public let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// 最近一次写入的块大小（采样帧），读端据此计算最小安全余量
    public let lastChunk = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private(set) var sampleRate: Float = 48000

    private var filter: Biquad
    private var filterRate: Float = 0
    private let highpassHz: Float

    // 音量归一化：采集到的是播放器调过音量之后的声音，播放器音量一变，手柄就跟着变。
    // 这里把电平归一到固定目标，手柄音量只由 App 里的滑块决定（和震动强度一样独立）
    public static let agcTargetRMS: Float = 0.2      // 约 -14dBFS
    public static let agcMaxBoost: Float = 30        // 最多 +29.5dB：播放器音量拉得很低也能补回来
    public static let agcMinGain: Float = 0.25       // 最多 -12dB：来源特别响时压下来
    public static let agcGateRMS: Float = 0.0005     // 低于约 -66dBFS 视为静音，不放大（避免把底噪放出来）
    private var agcLevel: Float = 0           // 均方电平
    private(set) var agcGain: Float = 1

    public init(highpassHz: Float = 200) {
        self.highpassHz = highpassHz
        filter = Biquad.highpass(hz: highpassHz, sampleRate: 48000)
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.size)
        buffer.initialize(repeating: 0, count: Self.size)
        written.initialize(to: 0)
        lastChunk.initialize(to: 0)
    }

    deinit {
        buffer.deallocate(); written.deallocate(); lastChunk.deallocate()
    }

    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate sr: Float) {
        if sr != filterRate {
            filter = Biquad.highpass(hz: highpassHz, sampleRate: sr)
            filterRate = sr
        }
        sampleRate = sr
        // 电平：起 5ms、落 1.5s；增益：需要降低时 10ms 跟上，需要升高时 0.5s 慢慢抬（避免忽大忽小）
        let levelUp = 1 - expf(-1 / (0.005 * sr)), levelDown = 1 - expf(-1 / (1.5 * sr))
        let gainDown = 1 - expf(-1 / (0.01 * sr)), gainUp = 1 - expf(-1 / (0.5 * sr))
        var pos = written.pointee
        for i in 0..<frames {
            let y = filter.process((left[i] + right[i]) * 0.5)
            let sq = y * y
            agcLevel += (sq - agcLevel) * (sq > agcLevel ? levelUp : levelDown)
            let rms = sqrtf(agcLevel)
            if rms > Self.agcGateRMS {
                let want = min(max(Self.agcTargetRMS / rms, Self.agcMinGain), Self.agcMaxBoost)
                agcGain += (want - agcGain) * (want < agcGain ? gainDown : gainUp)
            }
            buffer[pos & Self.mask] = y * agcGain
            pos += 1
        }
        lastChunk.pointee = frames
        written.pointee = pos
    }
}
