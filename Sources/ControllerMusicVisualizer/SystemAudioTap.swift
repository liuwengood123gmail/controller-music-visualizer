import AudioToolbox
import CoreAudio
import Foundation

/// 用 Core Audio process tap 旁听整机正在播放的声音（muteBehavior = unmuted，不影响原有播放）
final class SystemAudioTap {
    /// 回调在音频线程：左声道、右声道、帧数、采样率
    var onAudio: ((UnsafePointer<Float>, UnsafePointer<Float>, Int, Float) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "SystemAudioTap", qos: .userInteractive)
    private var scratchL = [Float](repeating: 0, count: 8192)
    private var scratchR = [Float](repeating: 0, count: 8192)
    private var sampleRate: Float = 48000

    /// 聚合设备的 ID（读取输入缓冲 / 延迟数值用）；未启动时为 kAudioObjectUnknown
    var deviceID: AudioObjectID { aggregateID }

    /// ioFrames：把聚合设备的 IO 缓冲设小以降低采集延迟（夹在设备允许的范围内，设置失败就保持系统默认）
    func start(ioFrames: Int? = nil) throws {
        // 排除自己（HD 引擎往手柄输出的声音不能被采回来）
        let exclude = CA.ownProcessObject().map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "ControllerMusicVisualizer Tap"
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "创建系统声音采集")

        let asbd = CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        if asbd.mSampleRate > 0 { sampleRate = Float(asbd.mSampleRate) }

        let outputUID = CA.string(CA.defaultOutputDevice(), kAudioDevicePropertyDeviceUID) ?? ""
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ControllerMusicVisualizer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "创建聚合设备")

        if let ioFrames { CA.setBufferFrames(aggregateID, ioFrames) }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }, "创建采集回调")
        try check(AudioDeviceStart(aggregateID, procID), "开始采集")
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let lastBuf = abl.last, let lastData = lastBuf.mData else { return }
        // tap 的流排在聚合设备输入的最后：交错立体声 = 1 个 buffer；非交错 = 最后 2 个 buffer
        if lastBuf.mNumberChannels >= 2 {
            let ch = Int(lastBuf.mNumberChannels)
            let frames = min(Int(lastBuf.mDataByteSize) / (4 * ch), scratchL.count)
            let p = lastData.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                scratchL[i] = p[i * ch]
                scratchR[i] = p[i * ch + 1]
            }
            scratchL.withUnsafeBufferPointer { l in
                scratchR.withUnsafeBufferPointer { r in onAudio?(l.baseAddress!, r.baseAddress!, frames, sampleRate) }
            }
        } else if abl.count >= 2, let lData = abl[abl.count - 2].mData {
            let frames = Int(lastBuf.mDataByteSize) / 4
            onAudio?(lData.assumingMemoryBound(to: Float.self), lastData.assumingMemoryBound(to: Float.self),
                     frames, sampleRate)
        } else {
            let frames = Int(lastBuf.mDataByteSize) / 4
            let p = lastData.assumingMemoryBound(to: Float.self)
            onAudio?(p, p, frames, sampleRate)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
