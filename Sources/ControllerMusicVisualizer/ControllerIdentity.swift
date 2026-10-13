import Foundation

/// 手柄的稳定身份：用于持久化设置，也用来在 GameController / HID / 音频设备之间对号
struct ControllerIdentity: Hashable {
    enum Kind: String { case dualSense, gamepad }
    let kind: Kind
    let key: String

    /// DualSense：蓝牙优先用序列号（通常是 MAC 地址），否则用 HID 的 LocationID（USB 实测没有序列号）
    static func dualSense(locationID: Int?, serial: String?) -> ControllerIdentity {
        if let serial, !serial.isEmpty { return ControllerIdentity(kind: .dualSense, key: "ds:sn:\(serial)") }
        return ControllerIdentity(kind: .dualSense, key: "ds:loc:\(String(locationID ?? 0, radix: 16))")
    }

    /// 只有 GameController 能看到的 DualSense（HID 打不开时的后备）
    static func dualSenseGameController(index: Int) -> ControllerIdentity {
        ControllerIdentity(kind: .dualSense, key: "ds:gc:\(index)")
    }

    /// 其他手柄（8BitDo、DualShock 4、Xbox…）：厂商名 + 类别 + 在同类中的序号
    static func gamepad(vendor: String, category: String, index: Int) -> ControllerIdentity {
        ControllerIdentity(kind: .gamepad, key: "gc:\(vendor)|\(category)|\(index)")
    }
}

/// USB DualSense 的音频设备 UID 里带有 HID 的 LocationID（十六进制、不带 0x），结尾 `:1` = 输出，`:2` = 输入（麦克风）。
/// 例：UID `AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Wireless Controller:1120000:1`
/// 对应 LocationID 0x1120000。
enum DualSenseAudioMatch {
    static func matches(uid: String, locationID: Int) -> Bool {
        uid.hasSuffix(":\(String(locationID, radix: 16)):1")
    }
}
