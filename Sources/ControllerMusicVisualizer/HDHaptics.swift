import AudioToolbox
import CoreAudio
import Foundation
import ControllerCore

// MARK: - 手柄音频输出（HD 震动 + 扬声器）

/// USB 连接时 DualSense 是一个 4 声道音频设备：第 1/2 声道 → 内置扬声器（扬声器只收第 2 声道，两个都写同样的单声道），
/// 第 3/4 声道 → 左/右震动单元（HD 震动）。两者共用同一个 AUHAL、同一个读位置游标：
/// 天然同一时钟、同一延迟，扬声器里听到的鼓点和 HD 震动的载波是同一时刻的数据。
///
/// - HD 震动需要同时让 DualSenseHID 进入 hdHaptics 模式（关掉兼容震动开关），否则手柄会忽略第 3/4 声道。
///   输出 = 载波 × 强度。强度来自音乐分析或按摩波形；载波在按摩时是正弦（频率决定手感），
///   跟随音乐时是音乐本身的低频波形（底鼓、贝斯原样传到手上），低频不足时混入正弦。
/// - 扬声器需要 DualSenseHID 先把扬声器通路打开（路径 3），否则 macOS 下没有声音。
///   声音 = 共享的单声道（已高通）× 软件音量（渐变）→ 软限幅。
///
/// 两者可独立开关。只设本 App 打开的 AUHAL 实例，不改系统默认输出设备。
final class DualSenseAudioOutput {
    /// 渲染逻辑（载波、扬声器读位置、音量渐变、限幅）在 ControllerCore 里，这里只负责 AUHAL
    private let renderer: ControllerAudioRenderer
    private var unit: AudioUnit?
    /// 设备实际的 IO 缓冲帧数
    private(set) var ioFrames = 0

    init(device: AudioObjectID, waveform: HapticWaveform?, feed: SpeakerFeed?,
         haptics: Bool, tuning: SpeakerTuning) throws {
        let sr = CA.get(device, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
        renderer = ControllerAudioRenderer(sampleRate: Float(sr), waveform: waveform, feed: feed,
                                           haptics: haptics, tuning: tuning)

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CAError(what: "查找 HAL 输出", status: -1) }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "创建输出单元")
        guard let u else { throw CAError(what: "创建输出单元", status: -1) }
        unit = u

        // 只打开 DualSense 这个设备，不改系统默认输出
        var dev = device
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioObjectID>.size)), "选择 DualSense 设备")
        // IO 缓冲越小延迟越低；夹在设备允许的范围内
        CA.setBufferFrames(device, tuning.ioFrames)
        ioFrames = Int(CA.get(device, kAudioDevicePropertyBufferFrameSize, default: UInt32(0)))

        var fmt = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 4, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "设置 4 声道格式")
        var cb = AURenderCallbackStruct(inputProc: audioRender, inputProcRefCon: Unmanaged.passUnretained(renderer).toOpaque())
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "设置渲染回调")
        try check(AudioUnitInitialize(u), "初始化输出单元")
        try check(AudioOutputUnitStart(u), "启动输出")
    }

    /// 左右强度 0...1；freq 为正弦载波频率；useMusic 为 true 时载波改用音乐低频波形
    func set(left: Float, right: Float, freq: Float, useMusic: Bool) {
        renderer.set(left: left, right: right, freq: freq, useMusic: useMusic)
    }

    /// 扬声器的软件音量（线性增益，0 = 静音）；渲染线程里 10–20ms 渐变
    func setSpeakerGain(_ gain: Float) { renderer.setSpeakerGain(gain) }

    /// 当前环形缓冲余量（毫秒）和累计欠载次数（调试显示用）
    var marginMs: Double { renderer.marginMs }
    var underruns: Int { renderer.underruns }

    func stop() {
        guard let u = unit else { return }
        unit = nil
        // 扬声器先淡出再停，避免咔哒声
        if renderer.speakerAudible {
            renderer.setSpeakerGain(0)
            usleep(25_000)
        }
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
    }

    deinit { stop() }
}

private let audioRender: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let renderer = Unmanaged<ControllerAudioRenderer>.fromOpaque(refCon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    guard abl.count >= 4,
          let spkL = abl[0].mData?.assumingMemoryBound(to: Float.self),
          let spkR = abl[1].mData?.assumingMemoryBound(to: Float.self),
          let outL = abl[2].mData?.assumingMemoryBound(to: Float.self),
          let outR = abl[3].mData?.assumingMemoryBound(to: Float.self) else {
        for buf in abl { if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) } }
        return noErr
    }
    for buf in abl.dropFirst(4) { if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) } }
    renderer.render(speakerLeft: spkL, speakerRight: spkR, hapticLeft: outL, hapticRight: outR, frames: Int(frames))
    return noErr
}
