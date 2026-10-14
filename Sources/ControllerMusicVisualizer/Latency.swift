import Foundation

/// 一个音频设备（某个方向）的延迟相关数值，单位：采样帧
struct DeviceTiming: Equatable {
    var sampleRate: Double = 48000
    var bufferFrames = 0
    var safetyOffset = 0
    var deviceLatency = 0
    var streamLatency = 0

    /// IO 缓冲 + 安全偏移 + 设备延迟 + 流延迟（Core Audio 文档给出的总延迟组成）
    var totalFrames: Int { bufferFrames + safetyOffset + deviceLatency + streamLatency }
    var ms: Double { sampleRate > 0 ? Double(totalFrames) / sampleRate * 1000 : 0 }
}

/// 手柄扬声器相对 Mac 音响的延迟分解（毫秒）。时间原点 = 应用把声音写给系统的那一刻
struct LatencyBreakdown: Equatable {
    /// 系统声音采集（tap 聚合设备的输入缓冲等）
    var tapCaptureMs: Double
    /// 环形缓冲余量
    var marginMs: Double
    /// DualSense 输出设备（IO 缓冲 + 安全偏移 + 设备/流延迟）
    var controllerOutputMs: Double
    /// Mac 当前输出设备（音响）；读不到时为 nil
    var macOutputMs: Double?

    var controllerTotalMs: Double { tapCaptureMs + marginMs + controllerOutputMs }
    /// 手柄比 Mac 音响晚多少（读不到 Mac 输出时为 nil）
    var extraMs: Double? { macOutputMs.map { controllerTotalMs - $0 } }
}

enum LatencyModel {
    static func breakdown(tapInput: DeviceTiming, marginMs: Double, controller: DeviceTiming,
                          macOutput: DeviceTiming?) -> LatencyBreakdown {
        LatencyBreakdown(tapCaptureMs: tapInput.ms, marginMs: marginMs, controllerOutputMs: controller.ms,
                         macOutputMs: macOutput?.ms)
    }

    /// 环形缓冲的最小安全余量（毫秒）：写端按块到达，读端采样到的 lag 会因为两边时钟漂移，
    /// 每隔一段时间整块（chunk）跳变一次（模拟实测：只留半个块会反复欠载），
    /// 所以要留够一个整块 + 读完一个输出块，再加一点安全量。chunk、outBlock 都用源采样帧
    static func minMarginMs(chunkFrames: Int, outBlockFrames: Double, sampleRate: Double, safetyMs: Double = 1.5) -> Double {
        guard sampleRate > 0 else { return 20 }
        return (Double(chunkFrames) + outBlockFrames) / sampleRate * 1000 + safetyMs
    }

    /// 兼容震动（HID 报告 / CoreHaptics，不经音频）相对扬声器的对齐延迟（毫秒）。
    /// 采集之后：扬声器还要经过 余量 + 手柄输出；兼容震动只要 主循环平均等待半个 tick + HID 传输。
    /// 马达启动本身的滞后（硬件，无法在软件里算）没有计入——默认不再额外加，留给 speaker.hapticsDelayMs 本机微调。
    /// 结果取 5ms 的整数倍，最大 maxMs，不会为负
    static func compatHapticDelayMs(marginMs: Double, controllerOutputMs: Double,
                                    tickMs: Double = 10, hidMs: Double = 4, maxMs: Double = 20) -> Double {
        let speaker = marginMs + controllerOutputMs
        let compat = tickMs / 2 + hidMs
        let d = max(0, min(speaker - compat, maxMs))
        return (d / 5).rounded() * 5
    }

    /// HD 震动的包络来自主循环（采集后平均约半个 tick 才到），而载波在环形缓冲里已经等了 margin：
    /// 包络比载波早到，延迟它让两者对齐
    static func hdEnvelopeDelayMs(marginMs: Double, tickMs: Double = 10, maxMs: Double = 20) -> Double {
        max(0, min(marginMs - tickMs / 2, maxMs))
    }
}

/// 可调参数：用 `defaults write com.liuliu.ControllerMusicVisualizer <键> <值>` 修改，重启 App 生效；
/// 未设置时用这里调好的默认值（见 docs/controller-speaker-design.md §5.3）
struct SpeakerTuning: Equatable {
    /// 扬声器硬件音量，范围 0x3d–0x64（61–100）；实测低于有效范围等于静音
    var hwVolume: UInt8 = 0x64
    /// 扬声器前置放大 0–7
    var preamp: UInt8 = 2   // +6dB，与 Linux 驱动一致
    var highpassHz: Float = 200
    /// 环形缓冲目标余量（毫秒）；nil = 按块大小自动计算并自适应
    var bufferMs: Double?
    /// DualSense 输出的 IO 缓冲帧数
    var ioFrames = 128   // 本机实测 128 帧稳定、延迟约减半
    /// 系统声音采集（tap 聚合设备）的 IO 缓冲帧数
    var tapFrames = 128
    /// 兼容震动相对扬声器的对齐延迟（毫秒，可正可负；负 = 反过来延迟扬声器）；nil = 按延迟模型估算
    var hapticsDelayMs: Double?

    static let keys = ["speaker.hwVolume", "speaker.preamp", "speaker.highpassHz", "speaker.bufferMs",
                       "speaker.ioFrames", "speaker.tapFrames", "speaker.hapticsDelayMs"]

    static func load(from d: UserDefaults = .standard) -> SpeakerTuning {
        var t = SpeakerTuning()
        func number(_ key: String) -> Double? { d.object(forKey: key) == nil ? nil : d.double(forKey: key) }
        if let v = number("speaker.hwVolume") { t.hwVolume = UInt8(min(max(v, 0x3d), 0x64)) }
        if let v = number("speaker.preamp") { t.preamp = UInt8(min(max(v, 0), 7)) }
        if let v = number("speaker.highpassHz") { t.highpassHz = Float(min(max(v, 20), 2000)) }
        if let v = number("speaker.bufferMs"), v > 0 { t.bufferMs = min(max(v, 2), 100) }
        if let v = number("speaker.ioFrames") { t.ioFrames = Int(min(max(v, 32), 2048)) }
        if let v = number("speaker.tapFrames") { t.tapFrames = Int(min(max(v, 32), 2048)) }
        if let v = number("speaker.hapticsDelayMs") { t.hapticsDelayMs = min(max(v, -50), 100) }
        return t
    }
}
