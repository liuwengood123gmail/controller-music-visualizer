import ControllerCore
import Foundation

// ControllerCore 的 C 接口：给不能直接调用 Swift 的平台用（Android 经 JNI 的 C 薄层调用；以后 Windows 的 C# 经 P/Invoke）。
// 约定：
// - 对象用不透明指针（`cv_*_create` 返回，`cv_*_destroy` 释放），内部是 Unmanaged 持有的 Swift 对象；
// - 数字直接传；复杂结构用 UTF-8 JSON（与 Swift 的 Codable 一致，字段见 contract/fixtures）；
// - 返回字符串时由调用方提供缓冲区，返回写入的字节数（不含结尾 0），缓冲区不够时返回需要的字节数的相反数；
// - 线程：同一个对象不要在两个线程同时调用，例外见各函数说明。
// 头文件：android/engine/src/main/cpp/controller_core.h（与这里一一对应）。

/// C 接口版本：函数或数据布局变化时递增
@_cdecl("cv_api_version")
public func cv_api_version() -> Int32 { 1 }

// MARK: - 工具

private func retain<T: AnyObject>(_ o: T) -> UnsafeMutableRawPointer { Unmanaged.passRetained(o).toOpaque() }
private func take<T: AnyObject>(_ p: UnsafeMutableRawPointer, as: T.Type) -> T {
    Unmanaged<T>.fromOpaque(p).takeUnretainedValue()
}
private func release<T: AnyObject>(_ p: UnsafeMutableRawPointer?, as: T.Type) {
    guard let p else { return }
    Unmanaged<T>.fromOpaque(p).release()
}

private func decode<T: Decodable>(_ type: T.Type, _ json: UnsafePointer<CChar>?) -> T? {
    guard let json else { return nil }
    return try? JSONDecoder().decode(T.self, from: Data(String(cString: json).utf8))
}

/// 把字符串写进调用方的缓冲区（带结尾 0）
private func write(_ s: String, _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    let bytes = Array(s.utf8)
    guard let out, Int(cap) > bytes.count else { return -Int32(bytes.count + 1) }
    bytes.withUnsafeBufferPointer { b in
        b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { out.update(from: $0, count: bytes.count) }
    }
    out[bytes.count] = 0
    return Int32(bytes.count)
}

private func encode<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

// MARK: - 核心：音乐分析 + 扬声器 / HD 音乐波形的共享缓冲（所有手柄共用一份）

final class CVCore {
    let analyzer = MusicAnalyzer()
    let waveform = HapticWaveform()
    let feed: SpeakerFeed
    private var left: [Float] = [], right: [Float] = []

    init(highpassHz: Float) {
        feed = SpeakerFeed(highpassHz: highpassHz)
        analyzer.waveform = waveform
    }

    /// 采集线程调用：交错立体声 → 分析器 + 扬声器缓冲（与 macOS 采集回调相同）
    func process(_ interleaved: UnsafePointer<Float>, frames n: Int, sampleRate sr: Float) {
        if left.count < n { left = [Float](repeating: 0, count: n); right = left }
        for i in 0..<n { left[i] = interleaved[2 * i]; right[i] = interleaved[2 * i + 1] }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                analyzer.process(left: l.baseAddress!, right: r.baseAddress!, frames: n, sampleRate: sr)
                feed.write(left: l.baseAddress!, right: r.baseAddress!, frames: n, sampleRate: sr)
            }
        }
    }
}

@_cdecl("cv_core_create")
public func cv_core_create(_ highpassHz: Float) -> UnsafeMutableRawPointer {
    retain(CVCore(highpassHz: highpassHz > 0 ? highpassHz : 200))
}

@_cdecl("cv_core_destroy")
public func cv_core_destroy(_ core: UnsafeMutableRawPointer?) { release(core, as: CVCore.self) }

/// 重新开始采集前调用（清掉分析器的历史）
@_cdecl("cv_core_reset")
public func cv_core_reset(_ core: UnsafeMutableRawPointer) { take(core, as: CVCore.self).analyzer.reset() }

/// 采集线程：交错立体声 float32
@_cdecl("cv_core_process")
public func cv_core_process(_ core: UnsafeMutableRawPointer, _ interleaved: UnsafePointer<Float>,
                            _ frames: Int32, _ sampleRate: Float) {
    guard frames > 0 else { return }
    take(core, as: CVCore.self).process(interleaved, frames: Int(frames), sampleRate: sampleRate)
}

// MARK: - 会话：每 10ms 的计算（SessionEngine）

final class CVSession {
    var engine = SessionEngine()
    var settings = ControllerSettings()
}

/// `cv_session_tick` 的 flags 位
public enum CVFlag {
    public static let vibration: UInt32 = 1 << 0
    public static let triggers: UInt32 = 1 << 1
    public static let lights: UInt32 = 1 << 2
    public static let adaptiveTriggers: UInt32 = 1 << 3
    public static let playerLEDs: UInt32 = 1 << 4
    public static let hdActive: UInt32 = 1 << 5
}

/// `cv_session_tick` 输出数组的布局（float × CV_TICK_COUNT）。「没有」用 NaN（或 -1）表示
public enum CVTick {
    public static let intensity = 0, resistance = 1, motorLeft = 2, motorRight = 3
    public static let hd = 4, hdLeft = 5, hdRight = 6, hdFreq = 7, hdMusic = 8
    public static let light = 9, red = 10, green = 11, blue = 12, playerLEDs = 13
    public static let levelLeft = 14, levelRight = 15, randomNow = 16
    public static let count = 17
}

@_cdecl("cv_session_create")
public func cv_session_create() -> UnsafeMutableRawPointer { retain(CVSession()) }

@_cdecl("cv_session_destroy")
public func cv_session_destroy(_ s: UnsafeMutableRawPointer?) { release(s, as: CVSession.self) }

/// 输出通道（重新）启动时调用
@_cdecl("cv_session_reset")
public func cv_session_reset(_ s: UnsafeMutableRawPointer) { take(s, as: CVSession.self).engine.reset() }

/// 设置变化时调用（JSON = ControllerSettings，缺字段用默认值、越界会夹住）。返回 0 成功，-1 解析失败
@_cdecl("cv_session_set_settings")
public func cv_session_set_settings(_ s: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>?) -> Int32 {
    guard let settings = decode(ControllerSettings.self, json) else { return -1 }
    take(s, as: CVSession.self).settings = settings
    return 0
}

/// 每 10ms 一次。core 提供本 tick 的音乐分析结果（可以为 NULL：没有采集时按静音算）。
/// L2/R2 改了强度时，会话自己的设置也随之更新（输出 intensity），调用方写回自己的设置即可
@_cdecl("cv_session_tick")
public func cv_session_tick(_ s: UnsafeMutableRawPointer, _ core: UnsafeMutableRawPointer?, _ flags: UInt32,
                            _ triggerLeft: Float, _ triggerRight: Float, _ dt: Float, _ alignDelayMs: Double,
                            _ out: UnsafeMutablePointer<Float>) {
    let session = take(s, as: CVSession.self)
    let music = core.map { take($0, as: CVCore.self).analyzer.current } ?? MusicFrame()
    let f = SessionFlags(vibration: flags & CVFlag.vibration != 0, triggers: flags & CVFlag.triggers != 0,
                         lights: flags & CVFlag.lights != 0, adaptiveTriggers: flags & CVFlag.adaptiveTriggers != 0,
                         playerLEDs: flags & CVFlag.playerLEDs != 0, hdActive: flags & CVFlag.hdActive != 0)
    let c = session.engine.tick(SessionTickInput(settings: session.settings, flags: f, music: music,
                                                 triggers: (triggerLeft, triggerRight), dt: dt,
                                                 alignDelayMs: alignDelayMs))
    if let v = c.intensity { session.settings.intensity = v }
    for i in 0..<CVTick.count { out[i] = .nan }
    if let v = c.intensity { out[CVTick.intensity] = v }
    if let v = c.triggerResistance { out[CVTick.resistance] = v }
    out[CVTick.motorLeft] = c.motors.left
    out[CVTick.motorRight] = c.motors.right
    out[CVTick.hd] = c.hd == nil ? 0 : 1
    if let hd = c.hd {
        out[CVTick.hdLeft] = hd.left; out[CVTick.hdRight] = hd.right
        out[CVTick.hdFreq] = hd.freq; out[CVTick.hdMusic] = hd.useMusic ? 1 : 0
    }
    out[CVTick.light] = c.light == nil ? 0 : 1
    if let l = c.light { out[CVTick.red] = l.r; out[CVTick.green] = l.g; out[CVTick.blue] = l.b }
    out[CVTick.playerLEDs] = c.playerLEDs.map(Float.init) ?? -1
    out[CVTick.levelLeft] = c.level.left
    out[CVTick.levelRight] = c.level.right
    out[CVTick.randomNow] = c.randomNow.flatMap { p in MassagePreset.allCases.firstIndex(of: p) }.map(Float.init) ?? -1
}

/// 震动相对扬声器 / HD 载波的对齐延迟（毫秒），规则同 macOS 的 ControllerSession.updateAlignment。
/// 只在跟随音乐、且手柄音频输出在运行时有意义；其余情况返回 0
@_cdecl("cv_align_delay_ms")
public func cv_align_delay_ms(_ hdActive: Int32, _ speakerOn: Int32, _ marginMs: Double,
                              _ controllerOutputMs: Double, _ hapticsDelayOverrideMs: Double) -> Double {
    if hdActive != 0 { return LatencyModel.hdEnvelopeDelayMs(marginMs: marginMs) }
    if speakerOn != 0 {
        let v = hapticsDelayOverrideMs.isNaN
            ? LatencyModel.compatHapticDelayMs(marginMs: marginMs, controllerOutputMs: controllerOutputMs)
            : hapticsDelayOverrideMs
        return max(v, 0)
    }
    return 0
}

// MARK: - DualSense 输出报告（DualSenseOutputController）

final class CVDualSense {
    var pending: [[UInt8]] = []
    var controller: DualSenseOutputController!

    init(bluetooth: Bool) {
        controller = DualSenseOutputController(bluetooth: bluetooth) { [unowned self] report in
            // 只排队，由调用方取走后真正发送（JNI 不需要从 Swift 反向调用 Java）
            if self.pending.count < 8 { self.pending.append(report) }
            return true
        }
    }
}

@_cdecl("cv_ds_create")
public func cv_ds_create(_ bluetooth: Int32) -> UnsafeMutableRawPointer { retain(CVDualSense(bluetooth: bluetooth != 0)) }

@_cdecl("cv_ds_destroy")
public func cv_ds_destroy(_ h: UnsafeMutableRawPointer?) { release(h, as: CVDualSense.self) }

/// 各项由 App 控制还是交给游戏（交出的项会立即排队一份「恢复默认」）
@_cdecl("cv_ds_set_controls")
public func cv_ds_set_controls(_ h: UnsafeMutableRawPointer, _ rumble: Int32, _ triggers: Int32, _ lights: Int32) {
    let c = take(h, as: CVDualSense.self).controller!
    c.controlsRumble = rumble != 0
    c.controlsTriggers = triggers != 0
    c.controlsLights = lights != 0
}

/// HD 震动模式（关掉兼容震动，手柄改由 USB 音频第 3/4 声道驱动）
@_cdecl("cv_ds_set_hd")
public func cv_ds_set_hd(_ h: UnsafeMutableRawPointer, _ on: Int32) { take(h, as: CVDualSense.self).controller.hdHaptics = on != 0 }

@_cdecl("cv_ds_set_speaker")
public func cv_ds_set_speaker(_ h: UnsafeMutableRawPointer, _ on: Int32, _ hwVolume: Int32, _ preamp: Int32) {
    take(h, as: CVDualSense.self).controller.setSpeaker(on != 0, hwVolume: UInt8(clamping: hwVolume),
                                                        preamp: UInt8(clamping: preamp))
}

@_cdecl("cv_ds_set_trigger_resistance")
public func cv_ds_set_trigger_resistance(_ h: UnsafeMutableRawPointer, _ v: Float) {
    take(h, as: CVDualSense.self).controller.setTriggerResistance(v)
}

@_cdecl("cv_ds_set_light")
public func cv_ds_set_light(_ h: UnsafeMutableRawPointer, _ r: Float, _ g: Float, _ b: Float) {
    take(h, as: CVDualSense.self).controller.setLight(r, g, b)
}

@_cdecl("cv_ds_set_player_leds")
public func cv_ds_set_player_leds(_ h: UnsafeMutableRawPointer, _ mask: Int32) {
    take(h, as: CVDualSense.self).controller.setPlayerLEDs(UInt8(clamping: mask))
}

/// 每 10ms 调用：马达强度，顺便负责定期重发（需要发送时排队一份报告）
@_cdecl("cv_ds_set_motors")
public func cv_ds_set_motors(_ h: UnsafeMutableRawPointer, _ l: Float, _ r: Float) {
    take(h, as: CVDualSense.self).controller.set(left: l, right: r)
}

/// 立即排队一份当前状态的报告（打开设备后的第一份）
@_cdecl("cv_ds_send")
public func cv_ds_send(_ h: UnsafeMutableRawPointer) { take(h, as: CVDualSense.self).controller.send() }

/// 停止：App 控制的项恢复默认，排队最后一份报告
@_cdecl("cv_ds_stop")
public func cv_ds_stop(_ h: UnsafeMutableRawPointer) { take(h, as: CVDualSense.self).controller.stop() }

/// 取出一份要发送的报告（含报告 ID，USB 48 字节 / 蓝牙 78 字节）。没有时返回 0；缓冲区不够返回 -1
@_cdecl("cv_ds_take_report")
public func cv_ds_take_report(_ h: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<UInt8>, _ cap: Int32) -> Int32 {
    let d = take(h, as: CVDualSense.self)
    guard let r = d.pending.first else { return 0 }
    guard r.count <= Int(cap) else { return -1 }
    d.pending.removeFirst()
    r.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: r.count) }
    return Int32(r.count)
}

/// 解析输入报告（USB 0x01 / 蓝牙 0x31）。out = [L2, R2, 电量 0–100, 是否充电]；成功返回 1
@_cdecl("cv_ds_parse_input")
public func cv_ds_parse_input(_ reportID: Int32, _ bytes: UnsafePointer<UInt8>, _ length: Int32,
                              _ out: UnsafeMutablePointer<Float>) -> Int32 {
    let b = Array(UnsafeBufferPointer(start: bytes, count: Int(max(length, 0))))
    guard let s = DualSenseReport.parseInput(reportID: UInt32(clamping: reportID), bytes: b) else { return 0 }
    out[0] = s.l2; out[1] = s.r2; out[2] = Float(s.batteryLevel); out[3] = s.charging ? 1 : 0
    return 1
}

// MARK: - 手柄 4 声道音频渲染（ControllerAudioRenderer）

final class CVRenderer {
    let renderer: ControllerAudioRenderer
    private var scratch: [UnsafeMutablePointer<Float>]
    private static let block = 1024

    init(core: CVCore, sampleRate: Float, haptics: Bool, tuning: SpeakerTuning) {
        renderer = ControllerAudioRenderer(sampleRate: sampleRate, waveform: core.waveform, feed: core.feed,
                                           haptics: haptics, tuning: tuning)
        scratch = (0..<4).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.block)
            p.initialize(repeating: 0, count: Self.block)
            return p
        }
    }

    deinit { scratch.forEach { $0.deallocate() } }

    /// 实时线程：交错输出。channels ≥ 4 时第 1–4 声道 = 扬声器左 / 右、HD 左 / 右，多余的声道写 0；
    /// channels == 2 时只写 HD（第 3/4 声道的内容）——设备只给出 2 声道时备用
    func render(_ out: UnsafeMutablePointer<Float>, channels: Int, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(Self.block, frames - done)
            renderer.render(speakerLeft: scratch[0], speakerRight: scratch[1],
                            hapticLeft: scratch[2], hapticRight: scratch[3], frames: n)
            for i in 0..<n {
                let o = out + (done + i) * channels
                if channels >= 4 {
                    o[0] = scratch[0][i]; o[1] = scratch[1][i]; o[2] = scratch[2][i]; o[3] = scratch[3][i]
                    if channels > 4 { for c in 4..<channels { o[c] = 0 } }
                } else {
                    for c in 0..<channels { o[c] = scratch[2 + min(c, 1)][i] }
                }
            }
            done += n
        }
    }
}

/// bufferMs / hapticsDelayMs 传 NaN = 用默认（自适应余量 / 按延迟模型）
@_cdecl("cv_renderer_create")
public func cv_renderer_create(_ core: UnsafeMutableRawPointer, _ sampleRate: Float, _ haptics: Int32,
                               _ bufferMs: Double, _ hapticsDelayMs: Double) -> UnsafeMutableRawPointer {
    var t = SpeakerTuning()
    if !bufferMs.isNaN, bufferMs > 0 { t.bufferMs = bufferMs }
    if !hapticsDelayMs.isNaN { t.hapticsDelayMs = hapticsDelayMs }
    return retain(CVRenderer(core: take(core, as: CVCore.self), sampleRate: sampleRate, haptics: haptics != 0, tuning: t))
}

@_cdecl("cv_renderer_destroy")
public func cv_renderer_destroy(_ h: UnsafeMutableRawPointer?) { release(h, as: CVRenderer.self) }

/// 主线程（任意非实时线程）：HD 强度 / 载波
@_cdecl("cv_renderer_set")
public func cv_renderer_set(_ h: UnsafeMutableRawPointer, _ l: Float, _ r: Float, _ freq: Float, _ useMusic: Int32) {
    take(h, as: CVRenderer.self).renderer.set(left: l, right: r, freq: freq, useMusic: useMusic != 0)
}

/// 扬声器软件音量：传 0…1 的滑块值（内部换算成增益）
@_cdecl("cv_renderer_set_speaker_volume")
public func cv_renderer_set_speaker_volume(_ h: UnsafeMutableRawPointer, _ volume: Float) {
    take(h, as: CVRenderer.self).renderer.setSpeakerGain(SpeakerVolume.gain(volume))
}

@_cdecl("cv_renderer_mute")
public func cv_renderer_mute(_ h: UnsafeMutableRawPointer) { take(h, as: CVRenderer.self).renderer.setSpeakerGain(0) }

@_cdecl("cv_renderer_speaker_audible")
public func cv_renderer_speaker_audible(_ h: UnsafeMutableRawPointer) -> Int32 {
    take(h, as: CVRenderer.self).renderer.speakerAudible ? 1 : 0
}

/// 实时线程（AAudio 回调）：不加锁、不分配内存
@_cdecl("cv_renderer_render")
public func cv_renderer_render(_ h: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<Float>,
                               _ channels: Int32, _ frames: Int32) {
    take(h, as: CVRenderer.self).render(out, channels: Int(channels), frames: Int(frames))
}

/// out = [当前余量 ms, 累计欠载次数]
@_cdecl("cv_renderer_stats")
public func cv_renderer_stats(_ h: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<Double>) {
    let r = take(h, as: CVRenderer.self).renderer
    out[0] = r.marginMs; out[1] = Double(r.underruns)
}

// MARK: - 设置（JSON）

/// 解析 → 夹住越界值 → 重新编码（各平台存储前统一过一遍）
@_cdecl("cv_settings_sanitize")
public func cv_settings_sanitize(_ json: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    write(encode((decode(ControllerSettings.self, json) ?? ControllerSettings()).sanitized), out, cap)
}

/// 新手柄的初始设置（D5）：remembered / copying 可为 NULL
@_cdecl("cv_settings_initial")
public func cv_settings_initial(_ remembered: UnsafePointer<CChar>?, _ copying: UnsafePointer<CChar>?,
                                _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    let s = ControllerSettings.initial(remembered: decode(ControllerSettings.self, remembered),
                                       copying: decode(ControllerSettings.self, copying))
    return write(encode(s), out, cap)
}

/// 把补丁合并进设置
@_cdecl("cv_settings_apply_patch")
public func cv_settings_apply_patch(_ settings: UnsafePointer<CChar>?, _ patch: UnsafePointer<CChar>?,
                                    _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    let s = decode(ControllerSettings.self, settings) ?? ControllerSettings()
    let p = decode(SettingsPatch.self, patch) ?? SettingsPatch()
    return write(encode(p.apply(to: s)), out, cap)
}

// MARK: - 会话对账（SessionReconciler）

private struct IdentityJSON: Codable { var kind: String; var key: String }
private struct ReconcileInput: Codable { var existing: [IdentityJSON]; var found: [IdentityJSON] }
private struct SlotJSON: Codable { var type: String; var session: Int?; var found: Int? }
private struct PlanJSON: Codable { var slots: [SlotJSON]; var removed: [Int]; var changed: Bool }

/// 输入 {"existing":[{"kind":"dualSense","key":"…"}],"found":[…]}；
/// 输出 {"slots":[{"type":"keep|migrate|add","session":i,"found":j}],"removed":[i],"changed":true}
@_cdecl("cv_reconcile")
public func cv_reconcile(_ json: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    guard let input = decode(ReconcileInput.self, json) else { return write("null", out, cap) }
    let id: (IdentityJSON) -> ControllerIdentity = {
        ControllerIdentity(kind: ControllerIdentity.Kind(rawValue: $0.kind) ?? .gamepad, key: $0.key)
    }
    let plan = SessionReconciler.plan(existing: input.existing.map(id), found: input.found.map(id))
    let slots = plan.slots.map { slot -> SlotJSON in
        switch slot {
        case .keep(let s, let f): return SlotJSON(type: "keep", session: s, found: f)
        case .migrate(let s, let f): return SlotJSON(type: "migrate", session: s, found: f)
        case .add(let f): return SlotJSON(type: "add", session: nil, found: f)
        }
    }
    return write(encode(PlanJSON(slots: slots, removed: plan.removed, changed: plan.changed)), out, cap)
}
