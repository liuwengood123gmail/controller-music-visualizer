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
        var c = [UInt8](repeating: 0, count: 47)
        c[0] = 0x01 | 0x02 | 0x04 | 0x08   // 兼容震动、震动选择、右扳机、左扳机
        c[1] = 0x04 | 0x10                  // 灯条、玩家指示灯
        c[2] = motorRight
        c[3] = motorLeft
        if resistance > 0 {
            // 扳机效果 0x01：阻力，参数 = 起点、力度
            for base in [10, 21] {
                c[base] = 0x01
                c[base + 1] = 0x08
                c[base + 2] = resistance
            }
        }
        c[38] = 0x04                        // 新固件的兼容震动开关
        c[43] = playerLEDs | 0x20           // bit5：立即亮灭，不渐变
        c[44] = light.0; c[45] = light.1; c[46] = light.2

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
