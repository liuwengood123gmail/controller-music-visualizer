import Foundation

/// 扬声器通路：on = 路径 3（耳机静音，扬声器 ← 右声道）+ 硬件音量 + 前置放大；
/// off = 路径 0（扬声器静音，交出控制权时发一次）；untouched = 不设置（手柄保留现状）
public enum SpeakerState: Equatable {
    case untouched
    case on(volume: UInt8, preamp: UInt8)
    case off
}

/// 一次输出报告要表达的状态（已经处理完「交给游戏」的默认值替换）
public struct DualSenseOutputState: Equatable {
    /// 是否设置震动 / 扳机 / 灯光（false = 交给游戏，对应的生效标志位不置）
    public var rumble = true, triggers = true, lights = true
    /// HD 模式：关掉兼容震动开关，手柄改由 USB 音频第 3/4 声道的波形驱动
    public var hd = false
    public var motorLeft: UInt8 = 0, motorRight: UInt8 = 0
    public var resistance: UInt8 = 0
    public var rgb: (UInt8, UInt8, UInt8) = (0, 64, 255)
    public var playerLEDs: UInt8 = 0b00100
    public var speaker: SpeakerState = .untouched

    public static func == (a: Self, b: Self) -> Bool {
        a.rumble == b.rumble && a.triggers == b.triggers && a.lights == b.lights && a.hd == b.hd
            && a.motorLeft == b.motorLeft && a.motorRight == b.motorRight && a.resistance == b.resistance
            && a.rgb == b.rgb && a.playerLEDs == b.playerLEDs && a.speaker == b.speaker
    }
}

/// DualSense 输出 / 输入报告的字节布局（参考 Linux hid-playstation）
public enum DualSenseReport {
    /// 47 字节的公共部分（dualsense_output_report_common）
    public static func common(_ s: DualSenseOutputState) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 47)
        // 震动标志位兼有模式切换作用（实测）：
        //   bit0 = 马达强度生效，bit1 = 保持兼容震动模式；两位都清零 → 手柄改用音频声道波形（HD）
        //   交给游戏时只置 bit1：手柄留在兼容模式，马达强度由游戏决定
        if s.rumble {
            c[0] = s.hd ? 0 : 0x01 | 0x02
            c[38] = s.hd ? 0 : 0x04     // 新固件的兼容震动开关
        } else {
            c[0] = 0x02
        }
        if s.triggers { c[0] |= 0x04 | 0x08 }   // 右扳机、左扳机
        if s.lights { c[1] = 0x04 | 0x10 }      // 灯条、玩家指示灯
        c[2] = s.motorRight
        c[3] = s.motorLeft
        if s.triggers && s.resistance > 0 {
            // 扳机效果 0x01：阻力，参数 = 起点、力度
            for base in [10, 21] {
                c[base] = 0x01
                c[base + 1] = 0x08
                c[base + 2] = s.resistance
            }
        }
        c[43] = s.playerLEDs | 0x20          // bit5：立即亮灭，不渐变
        c[44] = s.rgb.0; c[45] = s.rgb.1; c[46] = s.rgb.2
        // 扬声器字段：只用 |= 追加各自的生效标志位，不动 bit0/bit1（它们兼有震动模式切换作用）
        switch s.speaker {
        case .untouched:
            break
        case .on(let volume, let preamp):
            c[0] |= 0x20 | 0x80        // 扬声器音量、音频输出路径生效
            c[1] |= 0x80               // 前置放大生效
            c[5] = volume              // speaker_volume（有效范围约 0x3d–0x64）
            c[7] = 3 << 4              // audio_control bit4–5 = 3：耳机静音，扬声器 ← 右声道
            c[37] = preamp & 0x07      // audio_control2 bit0–2：扬声器前置放大
        case .off:
            c[0] |= 0x80
            c[7] = 0                   // 路径 0：扬声器静音
        }
        return c
    }

    /// USB：0x02 + common = 48 字节
    public static func usb(_ s: DualSenseOutputState) -> [UInt8] { [0x02] + common(s) }

    /// 蓝牙：0x31 + 序号 + 0x10 + common + 填充 + CRC32 = 78 字节
    public static func bluetooth(_ s: DualSenseOutputState, seq: UInt8) -> [UInt8] {
        var report = [0x31, seq << 4, 0x10] + common(s) + [UInt8](repeating: 0, count: 24) + [0, 0, 0, 0]
        let crc = crc32([0xA2] + report[0..<74])
        for i in 0..<4 { report[74 + i] = UInt8(truncatingIfNeeded: crc >> (8 * UInt32(i))) }
        return report
    }

    public static func make(_ s: DualSenseOutputState, bluetooth: Bool, seq: UInt8) -> [UInt8] {
        bluetooth ? Self.bluetooth(s, seq: seq) : usb(s)
    }

    public static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// 标准 CRC-32（zlib 同款），蓝牙输出报告需要
    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// 从输入报告里解析出的状态
public struct DualSenseInputState: Equatable {
    /// 扳机按压深度 0...1
    public var l2: Float = 0
    public var r2: Float = 0
    /// 电量 0–100 和是否在充电
    public var batteryLevel = 0
    public var charging = false

    public init() {}
}

extension DualSenseReport {
    /// 解析输入报告。USB：报告 0x01（64 字节，L2 在字节 5、R2 在字节 6）；
    /// 蓝牙：报告 0x31（整体后移 1 字节）。字节 0 是报告 ID；
    /// 系统回调里有时不带报告 ID（长度少 1），这里补上。
    /// 状态字节（USB 53 / 蓝牙 54）：低 4 位 = 电量（×10%），高 4 位 = 充电状态（0 放电 1 充电 2 已充满）
    public static func parseInput(reportID: UInt32, bytes: [UInt8]) -> DualSenseInputState? {
        var b = bytes
        let usbLength = 64, btLength = 78
        switch reportID {
        case 0x01:
            if b.count == usbLength - 1 { b.insert(0x01, at: 0) }
            guard b.count >= usbLength, b[0] == 0x01 else { return nil }
            return decode(b, shift: 0)
        case 0x31:
            if b.count == btLength - 1 { b.insert(0x31, at: 0) }
            guard b.count >= btLength, b[0] == 0x31 else { return nil }
            return decode(b, shift: 1)
        default:
            return nil
        }
    }

    private static func decode(_ b: [UInt8], shift: Int) -> DualSenseInputState {
        var s = DualSenseInputState()
        s.l2 = Float(b[5 + shift]) / 255
        s.r2 = Float(b[6 + shift]) / 255
        let status = b[53 + shift]
        let data = Int(status & 0x0F), chargingState = Int((status >> 4) & 0x0F)
        switch chargingState {
        case 2: s.batteryLevel = 100
        default: s.batteryLevel = min(data * 10 + 5, 100)
        }
        s.charging = chargingState == 1
        return s
    }
}
