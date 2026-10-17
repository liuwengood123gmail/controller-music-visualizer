import Foundation

/// 手柄 4 声道音频的渲染（与平台无关）：第 1/2 声道 → 内置扬声器（扬声器只收第 2 声道，两个都写同样的单声道），
/// 第 3/4 声道 → 左/右震动单元（HD 震动）。
///
/// 扬声器和 HD 音乐波形共用同一个读位置游标：两个缓冲在同一个采集回调里各写同样多的样本，位置一一对应，
/// 所以扬声器里听到的鼓点和 HD 震动的载波是同一时刻的数据。
///
/// 平台只负责打开设备、在设备的实时回调里调用 `render`（macOS：AUHAL；Windows：WASAPI；Android：AAudio）。
/// 线程约定：`set` / `setSpeakerGain` 由主线程调用（单个 Float / Bool，对齐读写）；
/// `render` 只在实时线程调用，内部不加锁、不分配内存。
public final class ControllerAudioRenderer {
    // 主线程写
    private var targetL: Float = 0, targetR: Float = 0, freq: Float = 150
    private var useMusic = false
    public let hapticsOn: Bool
    private var speakerTarget: Float = 0
    private let fixedMarginMs: Double     // > 0 时固定余量，不自适应
    private let extraLagMs: Double        // 额外让读位置更落后（用来延迟扬声器 / HD 载波）

    private let waveform: HapticWaveform?
    private let feed: SpeakerFeed?

    // 实时线程
    private var ampL: Float = 0, ampR: Float = 0, phase: Float = 0
    public let sampleRate: Float
    private let gainK: Float
    private var cursor = RingCursor()
    private var margin = AdaptiveMargin()
    private var gain = GainRamp()
    private var lastWritten = 0
    private var stalledBlocks = 0
    private var currentMarginMs: Double = 0

    public init(sampleRate: Float, waveform: HapticWaveform?, feed: SpeakerFeed?,
                haptics: Bool, tuning: SpeakerTuning) {
        self.sampleRate = sampleRate
        gainK = GainRamp.coefficient(sampleRate: sampleRate)
        self.waveform = waveform
        self.feed = feed
        hapticsOn = haptics
        fixedMarginMs = tuning.bufferMs ?? 0
        extraLagMs = max(-(tuning.hapticsDelayMs ?? 0), 0)
    }

    // MARK: - 主线程

    /// 左右强度 0...1；freq 为正弦载波频率；useMusic 为 true 时载波改用音乐低频波形
    public func set(left: Float, right: Float, freq: Float, useMusic: Bool) {
        targetL = left; targetR = right; self.freq = freq; self.useMusic = useMusic
    }

    /// 扬声器的软件音量（线性增益，0 = 静音）；渲染线程里 10–20ms 渐变
    public func setSpeakerGain(_ gain: Float) { speakerTarget = gain }

    /// 扬声器是否还有声音（停止前用来判断要不要等淡出）
    public var speakerAudible: Bool { speakerTarget > 0 || gain.value > 0.001 }

    /// 当前环形缓冲余量（毫秒）和累计欠载次数（调试显示用）
    public var marginMs: Double { currentMarginMs }
    public var underruns: Int { cursor.underruns }

    // MARK: - 实时线程

    /// 填满一块输出。四个指针分别是第 1–4 声道（非交错 float32），调用方先清零或不清零都可以
    public func render(speakerLeft spkL: UnsafeMutablePointer<Float>, speakerRight spkR: UnsafeMutablePointer<Float>,
                       hapticLeft outL: UnsafeMutablePointer<Float>, hapticRight outR: UnsafeMutablePointer<Float>,
                       frames n: Int) {
        let sr = sampleRate
        let blockSeconds = Double(n) / Double(sr)

        let speakerTarget = self.speakerTarget
        let speakerOn = speakerTarget > 0 || gain.value > 0.0005
        let wantsMusicWave = hapticsOn && useMusic && waveform != nil

        // 读位置：扬声器和 HD 音乐波形共用一个游标
        var pos = 0.0, step = 1.0
        var haveSource = false
        if (speakerOn || wantsMusicWave), let feed {
            let srate = Double(feed.sampleRate)
            let nominal = srate / Double(sr)
            let written = feed.written.pointee
            if written == lastWritten { stalledBlocks += 1 } else { stalledBlocks = 0; lastWritten = written }
            if stalledBlocks > 12 {
                cursor.stall()   // 采集停了：输出静音，数据恢复后重新对齐
            } else {
                let floorMs = LatencyModel.minMarginMs(chunkFrames: feed.lastChunk.pointee,
                                                       outBlockFrames: Double(n) * nominal, sampleRate: srate)
                let marginMs = (fixedMarginMs > 0 ? fixedMarginMs : floorMs + margin.extraMs) + extraLagMs
                currentMarginMs = marginMs
                let before = cursor.underruns
                step = cursor.prepare(written: Double(written), frames: n, nominalStep: nominal,
                                      target: marginMs * srate / 1000, blockSeconds: blockSeconds)
                margin.update(underrun: cursor.underruns > before, dt: blockSeconds)
                pos = cursor.readPos
                haveSource = true
            }
        }

        let inc = 2 * Float.pi * freq / sr
        let k = 1 - expf(-1 / (0.003 * sr))   // 强度 3ms 平滑，避免爆音
        let wave = wantsMusicWave && haveSource ? waveform : nil
        let src = haveSource ? feed : nil

        for i in 0..<n {
            let idx = Int(pos)
            // 扬声器：线性插值取样 × 软件音量（渐变）→ 软限幅，同样的单声道写到第 1、2 声道
            let g = gain.step(target: speakerTarget, k: gainK)
            if let src, g > 0.00001 {
                let f = Float(pos - Double(idx))
                let a = src.buffer[idx & SpeakerFeed.mask], b = src.buffer[(idx + 1) & SpeakerFeed.mask]
                let y = SoftLimiter.process((a + (b - a) * f) * g)
                spkL[i] = y; spkR[i] = y
            } else {
                spkL[i] = 0; spkR[i] = 0
            }

            // HD 震动：第 3/4 声道
            if hapticsOn {
                ampL += (targetL - ampL) * k
                ampR += (targetR - ampR) * k
                let sine = sinf(phase)
                phase += inc
                if phase > 2 * .pi { phase -= 2 * .pi }
                var cL = sine, cR = sine
                if let w = wave {
                    let wi = idx & HapticWaveform.mask
                    let wl = w.weight[0][wi], wr = w.weight[1][wi]
                    cL = wl * w.wave[0][wi] + (1 - wl) * sine
                    cR = wr * w.wave[1][wi] + (1 - wr) * sine
                }
                outL[i] = cL * ampL
                outR[i] = cR * ampR
            } else {
                outL[i] = 0; outR[i] = 0
            }
            pos += step
        }
        if haveSource { cursor.readPos = pos }
    }
}
