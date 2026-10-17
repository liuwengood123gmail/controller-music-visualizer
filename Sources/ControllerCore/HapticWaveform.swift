import Foundation

// MARK: - 音乐波形缓冲：系统声音 → HD 马达

/// 把系统声音的低频部分（底鼓、贝斯）整理成「单位幅度」的波形，交给 HD 输出当载波。
/// 采集线程写、HD 渲染线程读（单写单读的环形缓冲）。两边是不同的音频设备、时钟各自独立，
/// 读端按采样率比例取样，并把延迟维持在约 20ms。
public final class HapticWaveform {
    public static let size = 1 << 14
    public static let mask = size - 1

    /// 左右声道的单位幅度低频波形，以及「这一刻音乐低频有多充足」的权重 0...1
    public let wave: [UnsafeMutablePointer<Float>]
    public let weight: [UnsafeMutablePointer<Float>]
    /// 已写入的样本总数（arm64 上对齐的整数读写是原子的，单写单读够用）
    public let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private(set) var sampleRate: Float = 48000

    // 写端状态（只在采集线程访问）
    private var lp1: [Float] = [0, 0], lp2: [Float] = [0, 0]
    private var env: [Float] = [0, 0], peak: [Float] = [1e-3, 1e-3]
    private static let drive: Float = 2.2
    private static let driveNorm = tanhf(drive)

    public init() {
        wave = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.size)
            p.initialize(repeating: 0, count: Self.size); return p
        }
        weight = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.size)
            p.initialize(repeating: 0, count: Self.size); return p
        }
        written.initialize(to: 0)
    }

    deinit {
        (wave + weight).forEach { $0.deallocate() }
        written.deallocate()
    }

    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate sr: Float) {
        sampleRate = sr
        let a = 1 - expf(-2 * .pi * 300 / sr)          // 300Hz 二阶低通：底鼓、贝斯
        let rise = 1 - expf(-1 / (0.003 * sr)), fall = 1 - expf(-1 / (0.06 * sr))
        let peakDecay = expf(-1 / (3 * sr))
        var pos = written.pointee
        for i in 0..<frames {
            let idx = pos & Self.mask
            for (c, x) in [left[i], right[i]].enumerated() {
                lp1[c] += a * (x - lp1[c])
                lp2[c] += a * (lp1[c] - lp2[c])
                let y = lp2[c], m = abs(y)
                env[c] += (m - env[c]) * (m > env[c] ? rise : fall)
                peak[c] = max(env[c], peak[c] * peakDecay, 1e-4)
                // 除以包络得到单位幅度（正弦的峰值/平均绝对值 ≈ π/2）
                let u = min(max(y / max(env[c] * 1.57, 1e-6), -1), 1)
                // 实测马达在低频（约 50Hz）最有劲，底鼓、贝斯本来就在这个范围，直接用原波形；
                // tanh 软饱和把平均力度推高，又不硬削成方波
                wave[c][idx] = tanhf(Self.drive * u) / Self.driveNorm
                // 低频不足（如只有人声）时权重下降，HD 输出会逐渐换成正弦载波
                weight[c][idx] = min(env[c] / (0.15 * peak[c]), 1)
            }
            pos += 1
        }
        written.pointee = pos
    }
}
