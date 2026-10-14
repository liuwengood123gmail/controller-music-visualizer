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

    /// 当前连接的所有 DualSense（普通版 0x0CE6 / Edge 0x0DF2），按身份排序。
    /// 用一个常驻的 IOHIDManager；同一台手柄出现多个 HID 接口时只保留一个
    static func enumerate() -> [DualSenseInfo] {
        guard let manager = sharedManager,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var byKey: [String: DualSenseInfo] = [:]
        for d in devices {
            let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? ""
            let location = IOHIDDeviceGetProperty(d, kIOHIDLocationIDKey as CFString) as? Int
            let serial = IOHIDDeviceGetProperty(d, kIOHIDSerialNumberKey as CFString) as? String
            let bluetooth = transport.localizedCaseInsensitiveContains("Bluetooth")
            // 蓝牙才用序列号做身份；USB 用 LocationID
            let identity = ControllerIdentity.dualSense(locationID: location, serial: bluetooth ? serial : nil)
            let info = DualSenseInfo(device: d, manager: manager, locationID: location, bluetooth: bluetooth,
                                     identity: identity)
            if byKey[identity.key] == nil { byKey[identity.key] = info }
        }
        return byKey.values.sorted { $0.identity.key < $1.identity.key }
    }

    /// DualSense 插入或拔出（HID 层）时发出，注册表收到后立即重新扫描
    static let devicesChanged = Notification.Name("DualSenseHIDDevicesChanged")

    /// 必须挂到主线程的事件循环上：否则管理器收不到插拔通知，设备列表停留在创建那一刻，
    /// 运行中插入的手柄（包括蓝牙 → USB 切换）根本枚举不到，只能退回 GameController（后台扳机阻尼失效）
    private static let sharedManager: IOHIDManager? = {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [0x0CE6, 0x0DF2].map { [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let notify: IOHIDDeviceCallback = { _, _, _, _ in
            NotificationCenter.default.post(name: DualSenseHID.devicesChanged, object: nil)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, notify, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, notify, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess ? manager : nil
    }()

    /// 打开指定的 DualSense 并发一次初始报告；失败返回 nil
    static func open(_ info: DualSenseInfo) -> DualSenseHID? {
        // 共享管理器只会打开它启动时已连接的设备；之后插入（或换口重插）的手柄能被列出来，
        // 但没有被打开，发报告会失败、退回 GameController（后台扳机阻尼失效）。所以每次都显式打开设备
        IOHIDDeviceOpen(info.device, IOOptionBits(kIOHIDOptionsTypeNone))
        let hid = DualSenseHID(manager: info.manager, device: info.device, bluetooth: info.bluetooth)
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

        let state = DualSenseOutputState(rumble: rumble, triggers: triggers, lights: lights, hd: hd,
                                         motorLeft: motors.0, motorRight: motors.1, resistance: resist,
                                         rgb: rgb, playerLEDs: leds)
        let report = DualSenseReport.make(state, bluetooth: bluetooth, seq: seq)
        let reportID: CFIndex = bluetooth ? 0x31 : 0x02
        if bluetooth { seq = (seq + 1) & 0x0F }
        let ok = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, report, report.count) == kIOReturnSuccess
        dirty = false
        lastSent = Date()
        return ok
    }

    private func byte(_ v: Float) -> UInt8 { UInt8(clamping: Int((min(max(v, 0), 1) * 255).rounded())) }
}

/// 一台已连接的 DualSense 在 HID 层的描述
struct DualSenseInfo {
    let device: IOHIDDevice
    let manager: IOHIDManager
    /// HID LocationID（USB 时与音频设备 UID 里的数字对应）
    let locationID: Int?
    let bluetooth: Bool
    let identity: ControllerIdentity

    /// 是不是同一台手柄的同一种连接（不同则需要重启输出）
    func sameLink(as other: DualSenseInfo) -> Bool {
        CFEqual(device, other.device) && bluetooth == other.bluetooth
    }
}

/// 读取 DualSense 的输入报告（扳机、电量）。只读，不发送任何东西；
/// 这样 DualSense 的扳机读数不依赖 GameController，也就不用把 GCController 和 HID 设备对号。
final class DualSenseInput {
    private let device: IOHIDDevice
    private let buffer: UnsafeMutablePointer<UInt8>
    private static let bufferSize = 128
    private let lock = NSLock()
    private var current: DualSenseInputState?
    private var updated = Date.distantPast

    init(device: IOHIDDevice) {
        self.device = device
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))   // 同 DualSenseHID.open：换口重插的设备需要显式打开
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        buffer.initialize(repeating: 0, count: Self.bufferSize)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let me = Unmanaged<DualSenseInput>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            me.handle(reportID: reportID, bytes: bytes)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        buffer.deallocate()
    }

    /// 最近一次解析出的状态；还没收到过报告（例如蓝牙下尚未发过输出报告）时为 nil
    var state: DualSenseInputState? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// 0.5 秒内收到过输入报告时的状态。手柄持续上报输入，收不到通常是没有「输入监控」权限，
    /// 这时扳机读数应退回 GameController
    var freshState: DualSenseInputState? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(updated) < 0.5 ? current : nil
    }

    private func handle(reportID: UInt32, bytes: [UInt8]) {
        guard let s = DualSenseReport.parseInput(reportID: reportID, bytes: bytes) else { return }
        lock.lock(); current = s; updated = Date(); lock.unlock()
    }
}
