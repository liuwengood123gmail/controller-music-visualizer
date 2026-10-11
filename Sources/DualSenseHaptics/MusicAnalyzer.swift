import Foundation
import os

enum MusicMode: String, CaseIterable, Identifiable {
    case beat = "节拍"
    case bass = "低音"
    case envelope = "包络"
    var id: Self { self }
}

/// 分析结果：震动用的左右强度 + 灯光用的特征（灯光不受震动模式和强度影响）
struct MusicFrame {
    var vibration: (Float, Float) = (0, 0)
    /// 灯光亮度（左右），0...1：低音能量减去近期「暗部底线」后放大，鼓点间会明显变暗
    var level: (Float, Float) = (0, 0)
    /// 鼓点脉冲，鼓点瞬间为 1，随后衰减
    var beatPulse: Float = 0
    /// 音色高低 0...1：0 = 低沉（底鼓、贝斯），1 = 明亮（镲片、高音）。已按本首歌的范围拉伸并平滑
    var tone: Float = 0.5
}

/// 把左右声道的音频变成震动强度和灯光特征
final class MusicAnalyzer {
    var mode: MusicMode = .beat
    var sensitivity: Float = 0.5     // 0...1，鼓点检测灵敏度
    var responsiveness: Float = 0.7  // 0...1，越大跟随越快（尤其是声音变小时）

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
    private var beatAvg: Float = 0
    private var beatPulse: Float = 0
    private var sinceBeat: Float = 1
    // 音色分析：单声道四频段（<150 / 150–600 / 600–3k / >3kHz）
    private var toneLP: [Float] = [0, 0, 0]
    private var toneMin: Float = 7, toneMax: Float = 9   // 对数频率（log2 Hz）的近期范围
    private var tone: Float = 0.5

    func reset() {
        lp1 = [0, 0]; lp2 = [0, 0]
        bassPeak = [1e-3, 1e-3]; fullPeak = [1e-3, 1e-3]
        vibSmooth = [0, 0]; lightSmooth = [0, 0]; lightFloor = [0, 0]
        beatAvg = 0; beatPulse = 0; sinceBeat = 1
        toneLP = [0, 0, 0]; toneMin = 7; toneMax = 9; tone = 0.5
        output.withLock { $0 = MusicFrame() }
    }

    /// 快起、按响应速度回落的平滑
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
            let src = mode == .bass ? bass : full
            for c in 0..<2 {
                vibSmooth[c] = follow(vibSmooth[c], powf(src[c], 2), dt: dt)   // 指数越大，强弱对比越明显
                vib[c] = vibSmooth[c]
            }
        }

        updateTone(left: left, right: right, frames: frames, sampleRate: sampleRate, dt: dt)

        // 灯光：用低音（流行音乐全频响度被压得很平，低音才随节奏起伏），
        // 减去近期底线再放大，鼓点间变暗、鼓点上冲亮
        var light: [Float] = [0, 0]
        for c in 0..<2 {
            lightSmooth[c] = follow(lightSmooth[c], bass[c], dt: dt)
            let v = lightSmooth[c]
            // 底线：低于它立即跟下去，高于它时约 1.5 秒慢慢上浮
            lightFloor[c] = v < lightFloor[c] ? v : lightFloor[c] + (v - lightFloor[c]) * (1 - expf(-dt / 1.5))
            let contrast = (v - lightFloor[c]) / max(1 - lightFloor[c], 0.15)
            light[c] = powf(min(max(contrast, 0), 1), 1.3)
        }

        let frame = MusicFrame(vibration: (vib[0], vib[1]),
                               level: (light[0], light[1]),
                               beatPulse: beatPulse,
                               tone: tone)
        output.withLock { $0 = frame }
    }

    /// 音色重心：四个频段幅度加权的对数频率平均值，再按近期范围映射到 0...1
    private func updateTone(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                            frames: Int, sampleRate: Float, dt: Float) {
        let k = [150, 600, 3000].map { 1 - expf(-2 * .pi * Float($0) / sampleRate) }
        var sums: [Float] = [0, 0, 0, 0]
        var lp = toneLP
        for i in 0..<frames {
            let x = (left[i] + right[i]) * 0.5
            for j in 0..<3 { lp[j] += k[j] * (x - lp[j]) }
            let bands = [lp[0], lp[1] - lp[0], lp[2] - lp[1], x - lp[2]]
            for j in 0..<4 { sums[j] += bands[j] * bands[j] }
        }
        toneLP = lp

        let amps = sums.map { sqrtf($0 / Float(frames)) }
        let total = amps.reduce(0, +)
        guard total > 1e-4 else { return }   // 安静时保持上一个颜色

        let centers: [Float] = [80, 300, 1300, 6000].map { log2f($0) }
        let centroid = zip(amps, centers).reduce(0) { $0 + $1.0 * $1.1 } / total

        // 近期范围：超出立即扩展，平时以 8 秒时间常数向当前值收拢；至少保留 1 个八度，避免噪声被放大
        let relax = 1 - expf(-dt / 15)
        toneMin = min(centroid, toneMin + (centroid - toneMin) * relax)
        toneMax = max(centroid, toneMax + (centroid - toneMax) * relax)
        let span = max(toneMax - toneMin, 1)
        let target = min(max((centroid - toneMin) / span, 0), 1)

        tone += (target - tone) * (1 - expf(-dt / 0.8))    // 颜色约 0.8 秒平滑过渡
    }
}
