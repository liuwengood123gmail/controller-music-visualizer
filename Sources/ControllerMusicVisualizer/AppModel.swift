import AppKit
import ControllerCore
import CoreAudio
import Foundation
import GameController

/// macOS 的真实引擎（实现 ControllerCore 的 `ControllerEngine`）：开始 / 停止、100Hz 主循环、
/// 系统声音采集（只做一份，所有手柄共用）、权限提示、会话列表。每个手柄自己的东西都在 `ControllerSession` 里。
/// 界面只通过 `ControllerEngine` 接口和它打交道：发命令、订阅状态快照 / 电平 / 事件。
@MainActor
final class AppModel: ControllerEngine {
    let apiVersion = engineAPIVersion
    private let broadcaster = EngineBroadcaster()

    private var sessions: [ControllerSession] = []
    /// 界面当前选中的手柄：只用作「新手柄复制谁的设置」（D5）
    private var focusedID: ControllerID?
    private var running = false { didSet { stateDirty() } }
    private var errorMessage: Bilingual? { didSet { if errorMessage != oldValue { stateDirty() } } }
    private var notice: Bilingual? { didSet { if notice != oldValue { stateDirty() } } }
    private var options = GlobalOptions(
        blockHomeButton: UserDefaults.standard.object(forKey: "blockHomeButton") as? Bool ?? true)

    /// 屏蔽 PS 键（系统「主页键」）打开 macOS「游戏」：让系统把主页键交给 App 处理。
    /// Apple 的 preferredSystemGestureState，按文档通常只在 App 位于前台时生效
    func applyHomeButtonPolicy() {
        for c in GCController.controllers() {
            c.physicalInputProfile.buttons[GCInputButtonHome]?.preferredSystemGestureState =
                options.blockHomeButton ? .disabled : .enabled
        }
    }

    private let analyzer = MusicAnalyzer()
    private let waveform = HapticWaveform()
    private let tuning: SpeakerTuning
    /// 手柄扬声器要播放的声音（单声道、已高通），所有手柄共享一份
    private let speakerFeed: SpeakerFeed
    private let timingBox: TimingBox
    private let registry: ControllerRegistry
    private var tap: SystemAudioTap?
    private var tapGeneration = 0
    private var tapStarting = false
    private var tapFailed = false
    private var timer: Timer?
    private var lastTick = Date()
    private var frame = 0
    private var saveWork: DispatchWorkItem?
    /// 最近一次发出的状态快照
    private var published = EngineState()
    private var flushScheduled = false

    private var focused: ControllerSession? {
        sessions.first { $0.id == focusedID } ?? sessions.first
    }

    /// 至少有一个启用且 App 要控制点什么的手柄
    private var canStart: Bool { sessions.contains { $0.settings.enabled && !$0.allLeftToGame } }

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        tuning = SpeakerTuning.load(from: UserDefaults.standard)
        speakerFeed = SpeakerFeed(highpassHz: tuning.highpassHz)
        let box = TimingBox()
        timingBox = box
        registry = ControllerRegistry(store: SettingsStore(defaults: UserDefaults.standard), waveform: waveform, feed: speakerFeed, tuning: tuning,
                                      tapTiming: { box.provider?() })
        box.provider = { [weak self] in
            MainActor.assumeIsolated { () -> DeviceTiming? in
                guard let tap = self?.tap, tap.deviceID != kAudioObjectUnknown else { return nil }
                return CA.timing(tap.deviceID, scope: kAudioObjectPropertyScopeInput)
            }
        }
        analyzer.waveform = waveform

        let args = CommandLine.arguments
        // 调试用：--massage 让新手柄打开时显示按摩页
        registry.adjustNew = { settings in
            if args.contains("--massage") { settings.source = .massage }
        }
        registry.selectedSettings = { [weak self] in self?.focused?.settings }
        registry.onChange = { [weak self] added, removed in
            self?.sessionsChanged(added: added, removed: removed)
        }

        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, DualSenseHID.devicesChanged] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.registry.refresh()
                    self?.applyHomeButtonPolicy()   // 新连上的手柄也要设置
                }
            }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.forEach { $0.invalidateFeatures() } }
        }
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registry.saveAll() }
        }
        // 注意：本 App 创建/销毁采集用的聚合设备也会触发设备列表通知，
        // 所以 refresh() 只有手柄连接方式真的变了才会重启对应的会话，否则会无限重启卡死主线程。
        CA.onDevicesChanged { [weak self] in
            MainActor.assumeIsolated { self?.registry.refresh() }
        }
        GCController.startWirelessControllerDiscovery {}
        registry.refresh()
        applyHomeButtonPolicy()

        // 电量每 5 秒刷新一次（与是否在运行无关）；顺便再对一次连接情况，补上没有通知的 HID 插拔
        let housekeeping = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registry.refresh()
                self?.sessions.forEach { $0.refreshBattery(); $0.refreshLatency() }
            }
        }
        RunLoop.main.add(housekeeping, forMode: .common)

        // 调试用：open ControllerMusicVisualizer.app --args --autostart
        if args.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
    }

    // MARK: - ControllerEngine

    var state: EngineState { makeState() }

    var meters: [ControllerID: Meter] {
        var m: [ControllerID: Meter] = [:]
        for s in sessions where s.isActive { m[s.id] = Meter(left: s.level.0, right: s.level.1) }
        return m
    }

    func subscribe(_ handler: @escaping @MainActor (EngineUpdate) -> Void) -> EngineSubscription {
        let sub = broadcaster.subscribe(handler)
        published = makeState()
        handler(.state(published))
        handler(.meters(meters))
        return sub
    }

    func updateSettings(_ id: ControllerID, _ patch: SettingsPatch) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        s.apply(patch)
        flushState()   // 命令引起的变化立即发出，界面马上看到引擎接受后的值
    }

    func focus(_ id: ControllerID?) { focusedID = id }

    func setGlobalOptions(_ patch: GlobalOptionsPatch) {
        let new = patch.apply(to: options)
        guard new != options else { return }
        options = new
        UserDefaults.standard.set(options.blockHomeButton, forKey: "blockHomeButton")
        applyHomeButtonPolicy()
        flushState()
    }

    // MARK: - 状态快照

    private var capture: CaptureStatus {
        if tap != nil { return .running }
        if tapFailed, let errorMessage { return .failed(errorMessage) }
        if tapStarting { return .waitingForConsent }
        return .off
    }

    private func makeState() -> EngineState {
        EngineState(running: running, canStart: canStart, capture: capture,
                    controllers: sessions.map(\.info), notice: notice, error: errorMessage, options: options)
    }

    /// 内部变化：合并到下一拍再发（运行时由主循环约 33Hz 发，避免 L2/R2 调强度时每 10ms 重绘一次）
    private func stateDirty() {
        guard !flushScheduled else { return }
        flushScheduled = true
        if !running {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flushState() } }
        }
    }

    private func flushState() {
        flushScheduled = false
        guard broadcaster.hasSubscribers else { return }
        let s = makeState()
        guard s != published else { return }
        published = s
        broadcaster.publish(.state(s))
    }

    // MARK: - 会话列表

    private func sessionsChanged(added: [ControllerSession], removed: [ControllerSession]) {
        sessions = registry.sessions
        for s in added {
            s.onChange = { [weak self] in self?.stateDirty() }
            s.onSettingsChange = { [weak self] in self?.settingsDidChange() }
        }
        if running { added.forEach { $0.arm() } }
        if sessions.isEmpty && running { stop() }
        updateTap()
        stateDirty()
        for s in removed { broadcaster.publish(.event(.controllerDisconnected(s.id))) }
        for s in added { broadcaster.publish(.event(.controllerConnected(s.id))) }
    }

    private func settingsDidChange() {
        updateTap()
        stateDirty()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.registry.saveAll() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - 开始 / 停止

    func start() {
        guard !running else { return }
        guard canStart else {
            errorMessage = sessions.isEmpty
                ? Bilingual(zh: "没有找到手柄", en: "No controller found")
                : Bilingual(zh: "没有启用的手柄", en: "No controller enabled")
            flushState()
            return
        }
        errorMessage = nil
        running = true
        tapFailed = false
        sessions.forEach { $0.arm() }
        updateTap()

        lastTick = Date()
        let tm = Timer(timeInterval: 1.0 / 100, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        flushState()
    }

    func stop() {
        running = false
        stopTap()
        notice = nil
        timer?.invalidate()
        timer = nil
        sessions.forEach { $0.disarm() }
        flushState()
        broadcaster.publish(.meters([:]))
    }

    // MARK: - 系统声音采集

    private var needsTap: Bool { running && sessions.contains { $0.needsAudio } }

    private func updateTap() {
        if needsTap {
            if tap == nil && !tapStarting && !tapFailed { startTap() }
        } else if tap != nil || tapStarting {
            stopTap()
        }
    }

    private func stopTap() {
        defer { stateDirty() }
        tapGeneration += 1
        tapStarting = false
        tapFailed = false
        notice = nil
        tap?.stop()
        tap = nil
    }

    /// 系统声音采集放到后台线程启动：第一次会等用户回答「系统录音」权限弹窗，
    /// 这期间 Core Audio 调用会一直阻塞，放主线程会把整个界面卡死。
    private func startTap() {
        analyzer.reset()
        tapGeneration += 1
        tapStarting = true
        stateDirty()
        let generation = tapGeneration
        let t = SystemAudioTap()
        t.onAudio = { [analyzer, speakerFeed] l, r, n, sr in
            analyzer.process(left: l, right: r, frames: n, sampleRate: sr)
            speakerFeed.write(left: l, right: r, frames: n, sampleRate: sr)   // 与分析器同一回调、同样的样本数
        }
        let tapFrames = tuning.tapFrames
        let pending = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.tapGeneration == generation, self.tap == nil else { return }
                self.notice = Bilingual(
                    zh: "正在等待「系统录音」授权，请在弹出的对话框里点「允许」（可能出现在另一块屏幕上）",
                    en: "Waiting for System Audio Recording permission. Click Allow in the dialog (it may be on another display).")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: pending)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try t.start(ioFrames: tapFrames) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    pending.cancel()
                    guard let self else { t.stop(); return }
                    if self.tapGeneration == generation { self.tapStarting = false; self.stateDirty() }
                    guard self.tapGeneration == generation, self.needsTap else {
                        t.stop()   // 等授权期间已经停止或不再需要
                        return
                    }
                    self.notice = nil
                    if case .failure(let failure) = result {
                        self.tapFailed = true
                        self.errorMessage = Bilingual(
                            zh: "无法读取系统声音：\(failure)。请在 系统设置 → 隐私与安全性 → 录屏与系统录音 里允许本 App。",
                            en: "Cannot read system audio: \(failure). Allow this app in System Settings → Privacy & Security → Screen & System Audio Recording.")
                    } else {
                        self.tap = t
                        self.sessions.forEach { $0.refreshLatency() }
                    }
                }
            }
        }
    }

    // MARK: - 每 10ms 计算一次

    private func tick() {
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastTick))
        lastTick = now
        frame += 1
        let music = analyzer.current   // 一份分析结果，所有手柄共用
        for s in sessions { s.tick(music: music, dt: dt, count: frame) }
        // 电平和状态约 33Hz 发给界面
        if frame % 3 == 0 {
            if flushScheduled { flushState() }
            if broadcaster.hasSubscribers { broadcaster.publish(.meters(meters)) }
        }
    }
}

/// 让会话在不持有 AppModel 的情况下读到采集设备的延迟数值
final class TimingBox {
    var provider: (() -> DeviceTiming?)?
}
