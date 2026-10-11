import Foundation
import IOKit.hid

/// 直接向 DualSense 发送 HID 输出报告：震动、扳机阻尼、灯条合在一份报告里。
///
/// 为什么不用 GameController：macOS 只允许前台 App 设置扳机阻尼/灯条，
/// App 进入后台后系统会把它们重置，并用自己的输出报告不断覆盖。
/// 直接发报告则前台后台效果一致。
///
/// 报告格式参考 Linux hid-playstation 驱动（dualsense_output_report_common，47 字节）：
///   0 flag0  1 flag1  2 右马达  3 左马达  10…20 右扳机效果  21…31 左扳机效果
///   38 flag2  43 玩家指示灯（5 颗白灯）  44…46 灯条 RGB
/// USB：0x02 + common = 48 字节；蓝牙：0x31 + 序号 + 0x10 + common + 填充 + CRC32 = 78 字节
final class DualSenseHID: HapticOutput {
    let name: Bilingual

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let bluetooth: Bool
    var isBluetooth: Bool { bluetooth }

    /// HD 震动模式：关掉兼容震动开关，手柄改由 USB 音频第 3/4 声道的波形驱动（只有 USB 可用）
    var hdHaptics = false { didSet { if hdHaptics != oldValue { dirty = true } } }

    /// 各项由 App 控制还是交给游戏。交给游戏的项不设置「生效」标志位，手柄保留游戏的设置；
    /// 三项都交给游戏时完全不发报告。
    /// 手柄会一直保留最后收到的设置，所以交出去的那一刻先发一次「恢复默认」再放手
    var controlsRumble = true {
        didSet { if controlsRumble != oldValue { releaseRumble = !controlsRumble; handedOver() } }
    }
    var controlsTriggers = true {
        didSet { if controlsTriggers != oldValue { releaseTriggers = !controlsTriggers; handedOver() } }
    }
    var controlsLights = true {
        didSet { if controlsLights != oldValue { releaseLights = !controlsLights; handedOver() } }
    }
    private var releaseRumble = false, releaseTriggers = false, releaseLights = false

    /// 控制权变化后立即发送（交出的项这一次会发默认值）
    private func handedOver() {
        dirty = true
        flush()
    }
    private var seq: UInt8 = 0

    private var motorLeft: UInt8 = 0
    private var motorRight: UInt8 = 0
    private var resistance: UInt8 = 0
    private var light: (UInt8, UInt8, UInt8) = (0, 64, 255)
    private var playerLEDs: UInt8 = 0b00100   // 默认只亮中间一颗
    private var dirty = true
    private var lastSent = Date.distantPast

    /// 状态不变时也定期重发，盖掉系统在切换前后台时发出的重置
    private static let keepAlive: TimeInterval = 0.1

    private init(manager: IOHIDManager, device: IOHIDDevice, bluetooth: Bool) {
        self.manager = manager
        self.device = device
        self.bluetooth = bluetooth
        self.name = bluetooth ? Bilingual(zh: "直接控制（蓝牙）", en: "Direct control (Bluetooth)")
                              : Bilingual(zh: "直接控制（USB）", en: "Direct control (USB)")
    }

    /// 找到已连接的 DualSense（普通版 0x0CE6 / Edge 0x0DF2），优先 USB
    static func open() -> DualSenseHID? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [0x0CE6, 0x0DF2].map { [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }

        func transport(_ d: IOHIDDevice) -> String {
            IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? ""
        }
        let usb = devices.first { transport($0) == "USB" }
        let bt = devices.first { transport($0).localizedCaseInsensitiveContains("Bluetooth") }
        guard let device = usb ?? bt else { return nil }
        let hid = DualSenseHID(manager: manager, device: device, bluetooth: usb == nil)
        return hid.send() ? hid : nil
    }

    // MARK: - HapticOutput

    func set(left: Float, right: Float) {
        // DualSense 的兼容震动：左 = 重马达，右 = 轻马达
        let l = byte(left), r = byte(right)
        if l != motorLeft || r != motorRight {
            motorLeft = l; motorRight = r; dirty = true
        }
        flush()
    }

    func stop() {
        motorLeft = 0; motorRight = 0; resistance = 0
        light = (0, 64, 255)   // 恢复默认蓝色
        hdHaptics = false      // 恢复兼容震动，不影响其他游戏和 App
        playerLEDs = 0b00100
        _ = send()
    }

    // MARK: - 扳机 / 灯条

    /// 0 = 关闭，1 = 最硬
    func setTriggerResistance(_ strength: Float) {
        let v = byte(strength)
        if v != resistance { resistance = v; dirty = true }
    }

    func setLight(_ r: Float, _ g: Float, _ b: Float) {
        let c = (byte(r), byte(g), byte(b))
        if c != light { light = c; dirty = true }
    }

    /// 下方 5 颗白灯，bit0…bit4 从左到右
    func setPlayerLEDs(_ mask: UInt8) {
        let m = mask & 0x1F
        if m != playerLEDs { playerLEDs = m; dirty = true }
    }

    // MARK: - 发送

    private func flush() {
        if dirty || Date().timeIntervalSince(lastSent) > Self.keepAlive { _ = send() }
    }

    @discardableResult
    private func send() -> Bool {
        let rumble = controlsRumble || releaseRumble
        let triggers = controlsTriggers || releaseTriggers
        let lights = controlsLights || releaseLights
        guard rumble || triggers || lights else { return true }   // 全部交给游戏

        // 交出去的项：这一次发送默认值
        var motors = (motorLeft, motorRight), resist = resistance, rgb = light, leds = playerLEDs
        var hd = hdHaptics
        if releaseRumble { motors = (0, 0); hd = false }
        if releaseTriggers { resist = 0 }
        if releaseLights { rgb = (0, 64, 255); leds = 0b00100 }
        releaseRumble = false; releaseTriggers = false; releaseLights = false

        var c = [UInt8](repeating: 0, count: 47)
        // 震动标志位兼有模式切换作用（实测）：
        //   bit0 = 马达强度生效，bit1 = 保持兼容震动模式；两位都清零 → 手柄改用音频声道波形（HD）
        //   交给游戏时只置 bit1：手柄留在兼容模式，马达强度由游戏决定
        if rumble {
            c[0] = hd ? 0 : 0x01 | 0x02
            c[38] = hd ? 0 : 0x04     // 新固件的兼容震动开关
        } else {
            c[0] = 0x02
        }
        if triggers { c[0] |= 0x04 | 0x08 }   // 右扳机、左扳机
        if lights { c[1] = 0x04 | 0x10 }      // 灯条、玩家指示灯
        c[2] = motors.1
        c[3] = motors.0
        if triggers && resist > 0 {
            // 扳机效果 0x01：阻力，参数 = 起点、力度
            for base in [10, 21] {
                c[base] = 0x01
                c[base + 1] = 0x08
                c[base + 2] = resist
            }
        }
        c[43] = leds | 0x20                 // bit5：立即亮灭，不渐变
        c[44] = rgb.0; c[45] = rgb.1; c[46] = rgb.2

        var report: [UInt8]
        let reportID: CFIndex
        if bluetooth {
            report = [0x31, seq << 4, 0x10] + c + [UInt8](repeating: 0, count: 24) + [0, 0, 0, 0]
            seq = (seq + 1) & 0x0F
            let crc = crc32([0xA2] + report[0..<74])
            for i in 0..<4 { report[74 + i] = UInt8(truncatingIfNeeded: crc >> (8 * UInt32(i))) }
            reportID = 0x31
        } else {
            report = [0x02] + c
            reportID = 0x02
        }
        let ok = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, report, report.count) == kIOReturnSuccess
        dirty = false
        lastSent = Date()
        return ok
    }

    private func byte(_ v: Float) -> UInt8 { UInt8(clamping: Int((min(max(v, 0), 1) * 255).rounded())) }
}

/// 标准 CRC-32（zlib 同款），蓝牙输出报告需要
private let crcTable: [UInt32] = (0..<256).map { i in
    var c = UInt32(i)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

private func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
}
