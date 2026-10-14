import CoreAudio
import Foundation

/// 少量 Core Audio 属性读取封装
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = address(sel, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var v = value
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : value
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var s: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &s) == noErr else { return nil }
        return s?.takeRetainedValue() as String?
    }

    static func deviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func outputChannelCount(_ dev: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// USB 连接时，DualSense 会出现一个 4 声道输出设备（第 3/4 声道 = 左/右震动单元）。
    /// 给出 HID 的 LocationID 时按音频设备 UID 精确匹配（同时连多个 DualSense 时不会选错）
    static func dualSenseOutputDevice(locationID: Int? = nil) -> AudioObjectID? {
        deviceIDs().first {
            guard (string($0, kAudioObjectPropertyName) ?? "").localizedCaseInsensitiveContains("DualSense"),
                  outputChannelCount($0) >= 4 else { return false }
            guard let locationID else { return true }
            guard let uid = string($0, kAudioDevicePropertyDeviceUID) else { return false }
            return DualSenseAudioMatch.matches(uid: uid, locationID: locationID)
        }
    }

    // MARK: - 延迟相关

    static func streamIDs(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// 某个方向的延迟数值（IO 缓冲、安全偏移、设备延迟、第一个流的延迟）
    static func timing(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> DeviceTiming {
        var t = DeviceTiming()
        t.sampleRate = get(dev, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
        t.bufferFrames = Int(get(dev, kAudioDevicePropertyBufferFrameSize, default: UInt32(0)))
        t.safetyOffset = Int(get(dev, kAudioDevicePropertySafetyOffset, scope: scope, default: UInt32(0)))
        t.deviceLatency = Int(get(dev, kAudioDevicePropertyLatency, scope: scope, default: UInt32(0)))
        if let stream = streamIDs(dev, scope: scope).first {
            t.streamLatency = Int(get(stream, kAudioStreamPropertyLatency, default: UInt32(0)))
        }
        return t
    }

    /// 把 IO 缓冲帧数设为 frames，夹在设备允许的范围内；返回实际设置的值（设置失败返回 nil）。
    /// 注意是设备级属性：只对本 App 打开的设备调用，不会改变系统默认输出设备
    @discardableResult
    static func setBufferFrames(_ dev: AudioObjectID, _ frames: Int) -> Int? {
        let range = get(dev, kAudioDevicePropertyBufferFrameSizeRange,
                        default: AudioValueRange(mMinimum: 0, mMaximum: 0))
        var value = UInt32(frames)
        if range.mMaximum > 0 { value = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum)) }
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        guard AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        else { return nil }
        return Int(value)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    /// 本进程对应的 Core Audio process 对象（用于把自己排除在系统声音采集之外）
    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// 监听设备列表变化（插拔 USB 手柄）
    static func onDevicesChanged(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(system, &addr, .main) { _, _ in handler() }
    }
}

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) 失败 (\(status))" }
}

@discardableResult
func check(_ status: OSStatus, _ what: String) throws -> OSStatus {
    if status != noErr { throw CAError(what: what, status: status) }
    return status
}
