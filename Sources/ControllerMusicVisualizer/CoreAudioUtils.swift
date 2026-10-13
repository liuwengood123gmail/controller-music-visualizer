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
