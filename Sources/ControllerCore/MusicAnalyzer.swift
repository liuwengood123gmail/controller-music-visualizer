import Foundation

public enum MusicMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case beat = "节拍"
    case bass = "低音"
    case envelope = "包络"
    public var id: Self { self }

    public var title: String {
        switch self {
        case .beat: L("节拍", "Beat")
        case .bass: L("低音", "Bass")
        case .envelope: L("包络", "Envelope")
        }
    }

    /// HD 载波频率范围（Hz）：震动弱时用 high（细腻），强时降到 low。
    /// 实测马达在 50–65Hz 最有劲（比兼容震动最大值还强），低于 50Hz 反而变弱，所以 low 不低于 50
    public var carrierRange: (low: Float, high: Float) {
        switch self {
        case .beat: (55, 120)
        case .bass: (50, 90)
        case .envelope: (55, 110)
        }
    }
}

/// 分析结果：只含与具体手柄无关的原始特征。每个手柄的会话再按自己的设置
///（模式、响应速度、鼓点灵敏度、灯条速度…）整形成震动和灯光，见 Shaping.swift
public struct MusicFrame: Sendable {
    /// 低音能量（自动增益后 0...1，左右）
    public var bass: (Float, Float) = (0, 0)
    /// 低音的相对强度（左右）：按分贝记住近 2 秒的最小、最大音量，把当前音量映射到两者之间，0...1，未平滑
    public var bassRelative: (Float, Float) = (0, 0)
    /// 全频的相对强度（左右），0...1，未平滑
    public var fullRelative: (Float, Float) = (0, 0)
    /// 灯光亮度（左右），0...1：低音能量减去近期「暗部底线」后放大，鼓点间会明显变暗
    public var light: (Float, Float) = (0, 0)
    /// 白点电平（左右），0...1：当前音量在近 2 秒最小～最大音量之间的相对位置（分贝），近似实时
    public var meter: (Float, Float) = (0, 0)
    /// 灯条颜色（未锁定）：低频 → 红、中频 → 绿、高频 → 蓝，三路各自按能量混合，0...1
    public var color: (r: Float, g: Float, b: Float) = (0, 0, 0)
}

/// 相对强度：按分贝记住近 2 秒的最小、最大音量，把当前音量映射到两者之间（0...1）。
/// 本身很响、被压得很平的歌也能表现出起伏；两端至少相差 6dB，避免微小波动被放大成乱跳
public struct RelativeLevel {
    private var db: Float = -80
    private var lo: Float = -60
    private var hi: Float = -20

    /// rise / fall：分贝值的跟随时间常数（秒）
    public mutating func update(rms: Float, dt: Float, rise: Float = 0.003, fall: Float = 0.06) -> Float {
        let target = 20 * log10f(rms + 1e-5)
        db += (target - db) * (1 - expf(-dt / (target > db ? rise : fall)))
        let relax = 1 - expf(-dt / 2)
        lo = db < lo ? db : lo + (db - lo) * relax
        hi = db > hi ? db : hi + (db - hi) * relax
        guard rms >= 1e-4 else { return 0 }
        return min(max((db - lo) / max(hi - lo, 6), 0), 1)
    }
}

/// 把左右声道的音频变成震动和灯光的原始特征。只有一份，所有手柄共用（在音频线程运行）
public final class MusicAnalyzer {
    /// HD 震动用的音乐低频波形；设置后每块音频都会写进去
    public var waveform: HapticWaveform?

    private let output = LockedBox(MusicFrame())
    public var current: MusicFrame { output.withLock { $0 } }

    // 分析状态（只在音频线程访问）
    private var lp1: [Float] = [0, 0], lp2: [Float] = [0, 0]
    private var bassPeak: [Float] = [1e-3, 1e-3]
    private var lightSmooth: [Float] = [0, 0]
    private var lightFloor: [Float] = [0, 0]
    private var meterLevel = [RelativeLevel(), RelativeLevel()]
    private var bassLevel = [RelativeLevel(), RelativeLevel()]
    // 颜色：单声道三频段（<250 / 250–2500 / >2500 Hz），参考 audio-reactive-led-strip 的 energy 效果
    private var colorLP: [Float] = [0, 0, 0, 0]       // 250Hz、2500Hz 各两级一阶低通
    private var colorPeak: [Float] = [1e-3, 1e-3, 1e-3]
    private var colorSmooth: [Float] = [0, 0, 0]
    private var colorFloor: [Float] = [0, 0, 0]
    private var colorOut: [Float] = [0, 0, 0]

    public func reset() {
        lp1 = [0, 0]; lp2 = [0, 0]
        bassPeak = [1e-3, 1e-3]
        lightSmooth = [0, 0]; lightFloor = [0, 0]
        meterLevel = [RelativeLevel(), RelativeLevel()]; bassLevel = [RelativeLevel(), RelativeLevel()]
        colorLP = [0, 0, 0, 0]; colorPeak = [1e-3, 1e-3, 1e-3]; colorSmooth = [0, 0, 0]; colorFloor = [0, 0, 0]; colorOut = [0, 0, 0]
        output.withLock { $0 = MusicFrame() }
    }

    /// 灯光用的固定快速平滑（不受响应速度影响）：起 3ms、落 60ms，近似实时又不闪烁
    private func followLight(_ current: Float, _ target: Float, dt: Float) -> Float {
        let t: Float = target > current ? 0.003 : 0.06
        return current + (target - current) * (1 - expf(-dt / t))
    }

    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Float) {
        guard frames > 0 else { return }
        let dt = Float(frames) / sampleRate
        let a = 1 - expf(-2 * .pi * 150 / sampleRate)   // 150Hz 二阶低通

        var bassRMS: [Float] = [0, 0], fullRMS: [Float] = [0, 0]
        for (c, ptr) in [left, right].enumerated() {
            var y1 = lp1[c], y2 = lp2[c], bassSum: Float = 0, fullSum: Float = 0
            for i in 0..<frames {
                let x = ptr[i]
                y1 += a * (x - y1)
                y2 += a * (y1 - y2)
                bassSum += y2 * y2
                fullSum += x * x
            }
            lp1[c] = y1; lp2[c] = y2
            bassRMS[c] = sqrtf(bassSum / Float(frames))
            fullRMS[c] = sqrtf(fullSum / Float(frames))
        }

        // 自动增益：跟踪近几秒的峰值，安静的歌也能有反应
        let peakDecay = expf(-dt / 3)
        func normalize(_ rms: Float, _ peak: inout Float) -> Float {
            peak = max(rms, peak * peakDecay, 1e-3)
            return rms < 1e-4 ? 0 : min(rms / peak, 1)
        }
        var bass: [Float] = [0, 0]
        for c in 0..<2 {
            bass[c] = normalize(bassRMS[c], &bassPeak[c])
        }

        // 低音 / 全频的相对强度（各手柄自己决定用哪个、怎么平滑）
        var bassRel: [Float] = [0, 0]
        for c in 0..<2 { bassRel[c] = bassLevel[c].update(rms: bassRMS[c], dt: dt) }

        updateColor(left: left, right: right, frames: frames, sampleRate: sampleRate, dt: dt)
        waveform?.write(left: left, right: right, frames: frames, sampleRate: sampleRate)

        // 灯光：用低音（流行音乐全频响度被压得很平，低音才随节奏起伏），
        // 减去近期底线再放大，鼓点间变暗、鼓点上冲亮
        var light: [Float] = [0, 0]
        for c in 0..<2 {
            lightSmooth[c] = followLight(lightSmooth[c], bass[c], dt: dt)
            let v = lightSmooth[c]
            // 底线：低于它立即跟下去，高于它时约 1.5 秒慢慢上浮
            lightFloor[c] = v < lightFloor[c] ? v : lightFloor[c] + (v - lightFloor[c]) * (1 - expf(-dt / 1.5))
            let contrast = (v - lightFloor[c]) / max(1 - lightFloor[c], 0.15)
            light[c] = powf(min(max(contrast, 0), 1), 1.3)
        }

        // 白点：相对强度。按分贝记住近 2 秒的最小、最大音量，把当前音量映射到两者之间；
        // 本身很响的歌也只有相对最响的瞬间才点亮最外侧的灯
        var meterOut: [Float] = [0, 0]
        for c in 0..<2 { meterOut[c] = meterLevel[c].update(rms: fullRMS[c], dt: dt) }

        let frame = MusicFrame(bass: (bass[0], bass[1]),
                               bassRelative: (bassRel[0], bassRel[1]),
                               fullRelative: (meterOut[0], meterOut[1]),
                               light: (light[0], light[1]),
                               meter: (meterOut[0], meterOut[1]),
                               color: (colorOut[0], colorOut[1], colorOut[2]))
        output.withLock { $0 = frame }
    }

    /// 低/中/高三段能量 → 红/绿/蓝。每段按自己近几秒的峰值归一（不会被低音盖住），
    /// 平方加大对比，再用固定的快速平滑：几乎没有延迟，鼓点闪红、人声泛绿、镲片泛蓝
    private func updateColor(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                             frames: Int, sampleRate: Float, dt: Float) {
        let kLow = 1 - expf(-2 * .pi * 250 / sampleRate)
        let kHigh = 1 - expf(-2 * .pi * 2500 / sampleRate)
        var lp = colorLP
        var sums: [Float] = [0, 0, 0]
        for i in 0..<frames {
            let x = (left[i] + right[i]) * 0.5
            lp[0] += kLow * (x - lp[0]);   lp[1] += kLow * (lp[0] - lp[1])
            lp[2] += kHigh * (x - lp[2]);  lp[3] += kHigh * (lp[2] - lp[3])
            let low = lp[1], mid = lp[3] - lp[1], high = x - lp[3]
            sums[0] += low * low; sums[1] += mid * mid; sums[2] += high * high
        }
        colorLP = lp

        let peakDecay = expf(-dt / 3)
        for j in 0..<3 {
            let rms = sqrtf(sums[j] / Float(frames))
            colorPeak[j] = max(rms, colorPeak[j] * peakDecay, 1e-4)
            let norm = rms < 1e-4 ? 0 : min(rms / colorPeak[j], 1)
            colorSmooth[j] = followLight(colorSmooth[j], norm * norm, dt: dt)
            // 减掉一部分持续底色（持续的人声/混响变暗，突然出现的声音才亮），底色约 2 秒上浮
            let v = colorSmooth[j]
            colorFloor[j] = v < colorFloor[j] ? v : colorFloor[j] + (v - colorFloor[j]) * (1 - expf(-dt / 2))
            colorOut[j] = max(v - 0.6 * colorFloor[j], 0) / max(1 - 0.6 * colorFloor[j], 0.2)
        }

        // 提高饱和度：去掉三路共同部分的七成，再按原最大亮度放大回去（淡色变鲜艳，真正的全频爆发仍是白色）
        let mx = colorOut.max()!, mn = colorOut.min()!
        if mx > 1e-3 {
            let scale = mx / max(mx - 0.7 * mn, 1e-3)
            for j in 0..<3 { colorOut[j] = min((colorOut[j] - 0.7 * mn) * scale, 1) }
        }
    }
}
