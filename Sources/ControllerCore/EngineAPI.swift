import Foundation

// 界面与底层之间的「引擎接口」（docs/cross-platform-design.md §4.2）。
// 界面只通过它操作底层：发命令、订阅状态快照 / 电平 / 事件；底层不引用任何界面类型。
// 这里是 Swift 版（macOS 用；Windows 以后用它导出 C 接口）。Kotlin 版在 Android 工程里一一对应。

/// 接口版本：数据结构或语义变化时递增，界面启动时检查
public let engineAPIVersion = 1

/// 会话的稳定编号（UUID 字符串）。手柄在 USB ↔ 蓝牙之间切换时不变
public typealias ControllerID = String

public enum LinkKind: String, Codable, Sendable {
    case usb, bluetooth

    public var title: Bilingual {
        self == .usb ? Bilingual(zh: "USB", en: "USB") : Bilingual(zh: "蓝牙", en: "Bluetooth")
    }
}

public struct Battery: Equatable, Codable, Sendable {
    public var level: Int       // 0–100
    public var charging: Bool
    public init(level: Int, charging: Bool) { self.level = level; self.charging = charging }
}

/// 手柄能力：界面据此隐藏不支持的设置项（多手柄文档 D8）
public struct Capabilities: Equatable, Codable, Sendable {
    public var isDualSense: Bool
    public var hasLight: Bool
    public var hasAdaptiveTriggers: Bool
    /// HD 震动（USB DualSense）
    public var hasHD: Bool
    /// 手柄扬声器同步播放（USB DualSense）
    public var hasSpeaker: Bool
    public var canVibrate: Bool

    public init(isDualSense: Bool, hasLight: Bool, hasAdaptiveTriggers: Bool, hasHD: Bool,
                hasSpeaker: Bool, canVibrate: Bool) {
        self.isDualSense = isDualSense; self.hasLight = hasLight; self.hasAdaptiveTriggers = hasAdaptiveTriggers
        self.hasHD = hasHD; self.hasSpeaker = hasSpeaker; self.canVibrate = canVibrate
    }
}

/// 会话运行状态
public struct SessionStatus: Equatable, Codable, Sendable {
    /// 输出通道是否在运行
    public var isActive: Bool
    /// 引擎名称，例如「HD 震动（USB） + 手柄扬声器」；没在运行时是「—」
    public var engineName: Bilingual
    public var error: Bilingual?

    public init(isActive: Bool, engineName: Bilingual, error: Bilingual?) {
        self.isActive = isActive; self.engineName = engineName; self.error = error
    }
}

public struct ControllerInfo: Equatable, Codable, Identifiable, Sendable {
    public var id: ControllerID
    /// 设备名，例如「DualSense」「Pro Controller」
    public var name: String
    public var link: LinkKind?
    public var battery: Battery?
    public var capabilities: Capabilities
    /// 引擎持有的当前设置（唯一真源）
    public var settings: ControllerSettings
    public var status: SessionStatus
    /// 手柄扬声器相对电脑音响的延迟分解（扬声器同步播放运行时才有）
    public var latency: LatencyBreakdown?
    /// 调试信息：IO 缓冲帧数、环形缓冲余量、欠载次数
    public var audioStats: String?
    /// 随机按摩当前轮播到的预设
    public var randomNow: MassagePreset?

    public init(id: ControllerID, name: String, link: LinkKind?, battery: Battery?, capabilities: Capabilities,
                settings: ControllerSettings, status: SessionStatus, latency: LatencyBreakdown? = nil,
                audioStats: String? = nil, randomNow: MassagePreset? = nil) {
        self.id = id; self.name = name; self.link = link; self.battery = battery
        self.capabilities = capabilities; self.settings = settings; self.status = status
        self.latency = latency; self.audioStats = audioStats; self.randomNow = randomNow
    }

    /// 下拉框里的名称：「DualSense · USB · 95%」（按当前语言）
    public var title: String {
        var parts = [name]
        if let link { parts.append(link.title.text) }
        if let battery { parts.append("\(battery.level)%") }
        return parts.joined(separator: " · ")
    }
}

/// 系统声音采集的状态
public enum CaptureStatus: Equatable, Codable, Sendable {
    case off
    /// 等用户在系统弹窗里授权（macOS「系统录音」/ Android 屏幕录制）
    case waitingForConsent
    case running
    case failed(Bilingual)
}

/// 全局选项（不属于某个手柄）
public struct GlobalOptions: Equatable, Codable, Sendable {
    /// 屏蔽 PS 键打开系统「游戏」（macOS）
    public var blockHomeButton: Bool
    public init(blockHomeButton: Bool = true) { self.blockHomeButton = blockHomeButton }
}

public struct GlobalOptionsPatch: Equatable, Codable, Sendable {
    public var blockHomeButton: Bool?
    public init(blockHomeButton: Bool? = nil) { self.blockHomeButton = blockHomeButton }
    public func apply(to o: GlobalOptions) -> GlobalOptions {
        var o = o
        if let v = blockHomeButton { o.blockHomeButton = v }
        return o
    }
}

/// 引擎的状态快照（低频：有变化才发）
public struct EngineState: Equatable, Codable, Sendable {
    /// 全局「开始」是否按下（D3）
    public var running: Bool
    /// 至少有一个启用、且 App 要控制点什么的手柄（「开始」按钮是否可用）
    public var canStart: Bool
    public var capture: CaptureStatus
    public var controllers: [ControllerInfo]
    /// 提示（例如等待授权）
    public var notice: Bilingual?
    /// 全局错误（例如没有找到手柄、无法读取系统声音）
    public var error: Bilingual?
    public var options: GlobalOptions

    public init(running: Bool = false, canStart: Bool = false, capture: CaptureStatus = .off,
                controllers: [ControllerInfo] = [], notice: Bilingual? = nil, error: Bilingual? = nil,
                options: GlobalOptions = GlobalOptions()) {
        self.running = running; self.canStart = canStart; self.capture = capture
        self.controllers = controllers; self.notice = notice; self.error = error; self.options = options
    }

    public func controller(_ id: ControllerID?) -> ControllerInfo? {
        guard let id else { return nil }
        return controllers.first { $0.id == id }
    }
}

/// 电平（高频，约 30Hz）：只给电平条用
public struct Meter: Equatable, Codable, Sendable {
    public var left: Float, right: Float
    public init(left: Float, right: Float) { self.left = left; self.right = right }
    public static let zero = Meter(left: 0, right: 0)
}

/// 一次性事件
public enum EngineEvent: Equatable, Sendable {
    case controllerConnected(ControllerID)
    case controllerDisconnected(ControllerID)
}

public enum EngineUpdate: Sendable {
    case state(EngineState)
    case meters([ControllerID: Meter])
    case event(EngineEvent)
}

/// 订阅凭证：释放或调用 `cancel()` 后不再收到更新
public final class EngineSubscription {
    private var onCancel: (() -> Void)?
    public init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel?(); onCancel = nil }
    deinit { onCancel?() }
}

/// 引擎接口。所有调用都在主线程；更新也在主线程送达。
@MainActor
public protocol ControllerEngine: AnyObject {
    var apiVersion: Int { get }
    var state: EngineState { get }
    var meters: [ControllerID: Meter] { get }
    /// 订阅更新。订阅时会立即收到一次当前的 `.state` 和 `.meters`
    func subscribe(_ handler: @escaping @MainActor (EngineUpdate) -> Void) -> EngineSubscription

    /// 全局开始 / 停止（D3）
    func start()
    func stop()
    /// 只改补丁里给出的字段（每个字段最后一次写入为准）
    func updateSettings(_ id: ControllerID, _ patch: SettingsPatch)
    /// 界面当前选中的手柄：只用作「新手柄复制谁的设置」（D5）
    func focus(_ id: ControllerID?)
    func setGlobalOptions(_ patch: GlobalOptionsPatch)
}

/// 帮引擎实现「订阅 / 发布」
@MainActor
public final class EngineBroadcaster {
    private var handlers: [Int: @MainActor (EngineUpdate) -> Void] = [:]
    private var next = 0
    public init() {}

    public func subscribe(_ handler: @escaping @MainActor (EngineUpdate) -> Void) -> EngineSubscription {
        let key = next
        next += 1
        handlers[key] = handler
        return EngineSubscription { [weak self] in
            MainActor.assumeIsolated { _ = self?.handlers.removeValue(forKey: key) }
        }
    }

    public func publish(_ update: EngineUpdate) {
        for h in handlers.values { h(update) }
    }

    public var hasSubscribers: Bool { !handlers.isEmpty }
}
