import Foundation
import os

enum MusicMode: String, CaseIterable, Identifiable {
    case beat = "节拍"
    case bass = "低音"
    case envelope = "包络"
    var id: Self { self }

    var title: String {
        switch self {
        case .beat: L("节拍", "Beat")
        case .bass: L("低音", "Bass")
        case .envelope: L("包络", "Envelope")
        }
    }
}

/// 分析结果：震动用的左右强度 + 灯光用的特征（灯光不受震动模式和强度影响）
struct MusicFrame {
    var vibration: (Float, Float) = (0, 0)
    /// 灯光亮度（左右），0...1：低音能量减去近期「暗部底线」后放大，鼓点间会明显变暗
    var level: (Float, Float) = (0, 0)
    /// 白点电平（左右），0...1：当前音量在近 2 秒最小～最大音量之间的相对位置（分贝），近似实时
    var meter: (Float, Float) = (0, 0)
    /// 鼓点脉冲，鼓点瞬间为 1，随后衰减
    var beatPulse: Float = 0
    /// 灯条颜色：低频 → 红、中频 → 绿、高频 → 蓝，三路各自按能量混合，0...1
    var color: (r: Float, g: Float, b: Float) = (0, 0, 0)
    /// 灯条亮度 0...1（低音起伏，已按灯条速度平滑）；color 是已锁定的颜色，最亮通道 = 1
    var barLevel: Float = 0
}

/// 相对强度：按分贝记住近 2 秒的最小、最大音量，把当前音量映射到两者之间（0...1）。
/// 本身很响、被压得很平的歌也能表现出起伏；两端至少相差 6dB，避免微小波动被放大成乱跳
struct RelativeLevel {
    private var db: Float = -80
    private var lo: Float = -60
    private var hi: Float = -20

    /// rise / fall：分贝值的跟随时间常数（秒）
    mutating func update(rms: Float, dt: Float, rise: Float = 0.003, fall: Float = 0.06) -> Float {
        let target = 20 * log10f(rms + 1e-5)
        db += (target - db) * (1 - expf(-dt / (target > db ? rise : fall)))
        let relax = 1 - expf(-dt / 2)
        lo = db < lo ? db : lo + (db - lo) * relax
        hi = db > hi ? db : hi + (db - hi) * relax
        guard rms >= 1e-4 else { return 0 }
        return min(max((db - lo) / max(hi - lo, 6), 0), 1)
    }
}

/// 把左右声道的音频变成震动强度和灯光特征
final class MusicAnalyzer {
    var mode: MusicMode = .beat
    var sensitivity: Float = 0.5     // 0...1，鼓点检测灵敏度
    var responsiveness: Float = 0.7  // 0...1，震动跟随速度（尤其是声音变小时）
    var lightSpeed: Float = 0.3      // 0...1，灯条暗下去的速度：0 像呼吸灯，1 干脆地一闪一闪

    /// 按响应速度在「柔和」和「灵敏」两端之间取时间常数（对数插值）
    private func tau(soft: Float, fast: Float) -> Float {
        soft * powf(fast / soft, responsiveness)
    }

    private let output = OSAllocatedUnfairLock(initialState: MusicFrame())
    var current: MusicFrame { output.withLock { $0 } }

    // 分析状态（只在音频线程访问）
    private var lp1: [Float] = [0, 0], lp2: [Float] = [0, 0]
    private var bassPeak: [Float] = [1e-3, 1e-3]
    private var fullPeak: [Float] = [1e-3, 1e-3]
    private var vibSmooth: [Float] = [0, 0]
    private var lightSmooth: [Float] = [0, 0]
    private var lightFloor: [Float] = [0, 0]
    private var meterLevel = [RelativeLevel(), RelativeLevel()]
    private var vibLevel = [RelativeLevel(), RelativeLevel()]
    private var beatAvg: Float = 0
    private var beatPulse: Float = 0
    private var sinceBeat: Float = 1
    // 颜色：单声道三频段（<250 / 250–2500 / >2500 Hz），参考 audio-reactive-led-strip 的 energy 效果
    private var colorLP: [Float] = [0, 0, 0, 0]       // 250Hz、2500Hz 各两级一阶低通
    private var colorPeak: [Float] = [1e-3, 1e-3, 1e-3]
    private var colorSmooth: [Float] = [0, 0, 0]
    private var colorFloor: [Float] = [0, 0, 0]
    private var colorOut: [Float] = [0, 0, 0]
    // 离散换色：亮着时颜色锁定，暗到阈值以下后，下一次亮起时才按「点亮它的声音」换色
    private var lit = false
    private var barSmooth: Float = 0
    private var litTime: Float = 0
    private var falling = false
    private var latched: [Float] = [0, 0, 1]
    private var lightColor: [Float] = [0, 0, 0]
    private static let darkThreshold: Float = 0.12   // 低于它算暗了
    private static let litThreshold: Float = 0.25    // 高于它算重新亮起（两个门槛防止在边缘来回换色）

    func reset() {
        lp1 = [0, 0]; lp2 = [0, 0]
        bassPeak = [1e-3, 1e-3]; fullPeak = [1e-3, 1e-3]
        vibSmooth = [0, 0]; lightSmooth = [0, 0]; lightFloor = [0, 0]
        meterLevel = [RelativeLevel(), RelativeLevel()]; vibLevel = [RelativeLevel(), RelativeLevel()]
        beatAvg = 0; beatPulse = 0; sinceBeat = 1
        colorLP = [0, 0, 0, 0]; colorPeak = [1e-3, 1e-3, 1e-3]; colorSmooth = [0, 0, 0]; colorFloor = [0, 0, 0]; colorOut = [0, 0, 0]
        lit = false; barSmooth = 0; litTime = 0; falling = false; latched = [0, 0, 1]; lightColor = [0, 0, 0]
        output.withLock { $0 = MusicFrame() }
    }

    /// 灯光用的固定快速平滑（不受响应速度影响）：起 3ms、落 60ms，近似实时又不闪烁
    /// 灯条用：按「灯条速度」在 慢（起 20ms、落 300ms）和 快（起 3ms、落 60ms）之间取值
    private func followBar(_ current: Float, _ target: Float, dt: Float) -> Float {
        let rise = 0.02 * powf(0.15, lightSpeed), fall = 0.3 * powf(0.2, lightSpeed)
        let t = target > current ? rise : fall
        return current + (target - current) * (1 - expf(-dt / t))
    }

    private func followLight(_ current: Float, _ target: Float, dt: Float) -> Float {
        let t: Float = target > current ? 0.003 : 0.06
        return current + (target - current) * (1 - expf(-dt / t))
    }

    /// 震动用：快起、按响应速度回落的平滑
    private func follow(_ current: Float, _ target: Float, dt: Float) -> Float {
        // 上升：15ms → 5ms；下降：250ms → 30ms
        let t = target > current ? tau(soft: 0.015, fast: 0.005) : tau(soft: 0.25, fast: 0.03)
        return current + (target - current) * (1 - expf(-dt / t))
    }

    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Float) {
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
        var bass: [Float] = [0, 0], full: [Float] = [0, 0]
        for c in 0..<2 {
            bass[c] = normalize(bassRMS[c], &bassPeak[c])
            full[c] = normalize(fullRMS[c], &fullPeak[c])
        }

        // 鼓点检测（一直运行，节拍震动和灯光都用）：低音能量突然高于近期平均
        let mono = (bass[0] + bass[1]) / 2
        let threshold = 2.2 - 1.2 * sensitivity          // 灵敏度 0 → 2.2 倍，1 → 1.0 倍
        let minLevel = 0.45 - 0.25 * sensitivity
        sinceBeat += dt
        if mono > beatAvg * threshold && mono > minLevel && sinceBeat > 0.12 {
            beatPulse = 1
            sinceBeat = 0
        }
        beatAvg += (mono - beatAvg) * (1 - expf(-dt / 0.4))
        beatPulse *= expf(-dt / tau(soft: 0.15, fast: 0.04))

        // 震动
        var vib: [Float] = [0, 0]
        switch mode {
        case .beat:
            let maxB = max(bass[0], bass[1], 1e-3)
            vib = [beatPulse * bass[0] / maxB, beatPulse * bass[1] / maxB]
        case .bass, .envelope:
            // 相对强度（不受歌曲本身音量影响），平方加大对比，再按响应速度平滑
            let src = mode == .bass ? bassRMS : fullRMS
            for c in 0..<2 {
                let rel = vibLevel[c].update(rms: src[c], dt: dt)
                vibSmooth[c] = follow(vibSmooth[c], rel * rel, dt: dt)
                vib[c] = vibSmooth[c]
            }
        }

        updateColor(left: left, right: right, frames: frames, sampleRate: sampleRate, dt: dt)

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

        // 灯条：亮度跟随低音起伏（鼓点间会暗下去）；颜色只在「暗 → 亮」的瞬间按当时的三频段混合选定，亮着时保持
        // 先用快速跟随算出起伏，最后再按「灯条速度」平滑：调慢时两拍之间来不及暗透，像呼吸灯
        let previous = barSmooth
        barSmooth = followBar(barSmooth, max(light[0], light[1]), dt: dt)
        let brightness = barSmooth

        func latch() {
            if let m = colorOut.max(), m > 1e-3 { latched = colorOut.map { $0 / m } }   // 归一到最亮 = 1
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
        lightColor = latched

        let frame = MusicFrame(vibration: (vib[0], vib[1]),
                               level: (light[0], light[1]),
                               meter: (meterOut[0], meterOut[1]),
                               beatPulse: beatPulse,
                               color: (lightColor[0], lightColor[1], lightColor[2]),
                               barLevel: brightness)
        output.withLock { $0 = frame }
    }

    /// 低/中/高三段能量 → 红/绿/蓝。每段按自己近几秒的峰值归一（不会被低音盖住），
    /// 平方加大对比，再按响应速度平滑：几乎没有延迟，鼓点闪红、人声泛绿、镲片泛蓝
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
