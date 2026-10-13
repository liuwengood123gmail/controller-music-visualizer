import AudioToolbox
import CoreAudio
import Foundation

// MARK: - 音乐波形缓冲：系统声音 → HD 马达

/// 把系统声音的低频部分（底鼓、贝斯）整理成「单位幅度」的波形，交给 HD 输出当载波。
/// 采集线程写、HD 渲染线程读（单写单读的环形缓冲）。两边是不同的音频设备、时钟各自独立，
/// 读端按采样率比例取样，并把延迟维持在约 20ms。
final class HapticWaveform {
    static let size = 1 << 14
    static let mask = size - 1

    /// 左右声道的单位幅度低频波形，以及「这一刻音乐低频有多充足」的权重 0...1
    let wave: [UnsafeMutablePointer<Float>]
    let weight: [UnsafeMutablePointer<Float>]
    /// 已写入的样本总数（arm64 上对齐的整数读写是原子的，单写单读够用）
    let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private(set) var sampleRate: Float = 48000

    // 写端状态（只在采集线程访问）
    private var lp1: [Float] = [0, 0], lp2: [Float] = [0, 0]
    private var env: [Float] = [0, 0], peak: [Float] = [1e-3, 1e-3]
    private static let drive: Float = 2.2
    private static let driveNorm = tanhf(drive)

    init() {
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

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate sr: Float) {
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

// MARK: - HD 输出

/// HD 震动：USB 连接时 DualSense 是一个 4 声道音频设备，第 3/4 声道直接驱动左/右震动单元。
/// 需要同时让 DualSenseHID 进入 hdHaptics 模式（关掉兼容震动开关），否则手柄会忽略这两个声道。
///
/// 输出 = 载波 × 强度。强度来自音乐分析或按摩波形；载波在按摩时是正弦（频率决定手感），
/// 跟随音乐时是音乐本身的低频波形（底鼓、贝斯原样传到手上），低频不足时混入正弦。
final class HDHapticOutput {
    /// 渲染线程用到的全部状态
    fileprivate final class Context {
        var targetL: Float = 0, targetR: Float = 0, freq: Float = 150
        var useMusic = false
        var waveform: HapticWaveform?
        var ampL: Float = 0, ampR: Float = 0, phase: Float = 0
        var sampleRate: Float = 48000
        var readPos: Double = 0
    }

    private var unit: AudioUnit?
    private let ctx = Context()

    init(device: AudioObjectID, waveform: HapticWaveform?) throws {
        let sr = CA.get(device, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
        ctx.sampleRate = Float(sr)
        ctx.waveform = waveform

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CAError(what: "查找 HAL 输出", status: -1) }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "创建输出单元")
        guard let u else { throw CAError(what: "创建输出单元", status: -1) }
        unit = u

        // 只打开 DualSense 这个设备，不改系统默认输出；第 1/2 声道写静音，与系统声音叠加不覆盖
        var dev = device
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioObjectID>.size)), "选择 DualSense 设备")
        var fmt = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 4, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "设置 4 声道格式")
        var cb = AURenderCallbackStruct(inputProc: hdRender, inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque())
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "设置渲染回调")
        try check(AudioUnitInitialize(u), "初始化输出单元")
        try check(AudioOutputUnitStart(u), "启动输出")
    }

    /// 左右强度 0...1；freq 为正弦载波频率；useMusic 为 true 时载波改用音乐低频波形
    func set(left: Float, right: Float, freq: Float, useMusic: Bool) {
        ctx.targetL = left; ctx.targetR = right; ctx.freq = freq; ctx.useMusic = useMusic
    }

    func stop() {
        guard let u = unit else { return }
        unit = nil
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
    }

    deinit { stop() }
}

private let hdRender: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<HDHapticOutput.Context>.fromOpaque(refCon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    for buf in abl { if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) } }
    guard abl.count >= 4,
          let outL = abl[2].mData?.assumingMemoryBound(to: Float.self),
          let outR = abl[3].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

    let sr = ctx.sampleRate
    let inc = 2 * Float.pi * ctx.freq / sr
    let k = 1 - expf(-1 / (0.003 * sr))   // 强度 3ms 平滑，避免爆音
    let n = Int(frames)

    // 音乐波形：按两边采样率之比取样，读位置保持在写位置之后约 20ms
    var music: HapticWaveform?
    var step = 1.0
    if ctx.useMusic, let w = ctx.waveform {
        music = w
        step = Double(w.sampleRate / sr)
        let written = Double(w.written.pointee)
        let target = Double(w.sampleRate) * 0.02
        let lag = written - ctx.readPos
        if lag < Double(n) * step || lag > target * 3 { ctx.readPos = max(written - target, 0) }
    }

    for i in 0..<n {
        ctx.ampL += (ctx.targetL - ctx.ampL) * k
        ctx.ampR += (ctx.targetR - ctx.ampR) * k
        let sine = sinf(ctx.phase)
        ctx.phase += inc
        if ctx.phase > 2 * .pi { ctx.phase -= 2 * .pi }

        var cL = sine, cR = sine
        if let w = music {
            let idx = Int(ctx.readPos) & HapticWaveform.mask
            let wl = w.weight[0][idx], wr = w.weight[1][idx]
            cL = wl * w.wave[0][idx] + (1 - wl) * sine
            cR = wr * w.wave[1][idx] + (1 - wr) * sine
            ctx.readPos += step
        }
        outL[i] = cL * ctx.ampL
        outR[i] = cR * ctx.ampR
    }
    return noErr
}
