import Foundation

/// 假引擎：不连接任何设备，按剧本给出手柄列表和模拟电平。
/// 用途：界面开发（没有手柄也能完整操作）、SwiftUI 预览、界面测试。真实引擎换上来时界面不用改。
@MainActor
public final class FakeControllerEngine: ControllerEngine {
    public enum Scenario: String, CaseIterable, Sendable {
        /// 没有手柄
        case none
        /// 一个 USB DualSense
        case singleUSB
        /// USB DualSense + 蓝牙 DualSense + 8BitDo（Switch Pro 模式）
        case multi
        /// 系统声音采集被拒绝
        case captureDenied
    }

    public let apiVersion = engineAPIVersion
    public private(set) var state: EngineState
    public private(set) var meters: [ControllerID: Meter] = [:]
    private let broadcaster = EngineBroadcaster()
    private let scenario: Scenario
    private var time = 0.0

    public init(scenario: Scenario = .multi) {
        self.scenario = scenario
        state = EngineState(controllers: Self.controllers(for: scenario))
        state.canStart = Self.canStart(state.controllers)
    }

    public func subscribe(_ handler: @escaping @MainActor (EngineUpdate) -> Void) -> EngineSubscription {
        let sub = broadcaster.subscribe(handler)
        handler(.state(state))
        handler(.meters(meters))
        return sub
    }

    // MARK: - 命令

    public func start() {
        guard !state.running else { return }
        guard state.canStart else {
            state.error = state.controllers.isEmpty
                ? Bilingual(zh: "没有找到手柄", en: "No controller found")
                : Bilingual(zh: "没有启用的手柄", en: "No controller enabled")
            publishState()
            return
        }
        state.error = nil
        state.running = true
        if scenario == .captureDenied {
            state.capture = .failed(Bilingual(zh: "无法读取系统声音（假引擎模拟）", en: "Cannot read system audio (simulated)"))
            state.error = Bilingual(zh: "无法读取系统声音（假引擎模拟）。", en: "Cannot read system audio (simulated).")
        } else {
            state.capture = .running
        }
        refreshStatuses()
        publishState()
    }

    public func stop() {
        state.running = false
        state.capture = .off
        refreshStatuses()
        meters = [:]
        publishState()
        broadcaster.publish(.meters(meters))
    }

    public func updateSettings(_ id: ControllerID, _ patch: SettingsPatch) {
        guard let i = state.controllers.firstIndex(where: { $0.id == id }) else { return }
        state.controllers[i].settings = patch.apply(to: state.controllers[i].settings)
        state.canStart = Self.canStart(state.controllers)
        refreshStatuses()
        publishState()
    }

    public func focus(_ id: ControllerID?) {}

    public func setGlobalOptions(_ patch: GlobalOptionsPatch) {
        state.options = patch.apply(to: state.options)
        publishState()
    }

    // MARK: - 模拟

    /// 推进模拟时间：运行中时给出正弦电平（界面可以用定时器每 33ms 调一次）
    public func advance(by dt: Double) {
        time += dt
        guard state.running else { return }
        var m: [ControllerID: Meter] = [:]
        for (k, c) in state.controllers.enumerated() where c.status.isActive {
            let phase = time * 2 * .pi * (0.7 + 0.3 * Double(k))
            let i = Float(c.settings.intensity)
            m[c.id] = Meter(left: min(Float(0.5 + 0.5 * sin(phase)) * i, 1),
                            right: min(Float(0.5 + 0.5 * cos(phase * 1.3)) * i, 1))
        }
        meters = m
        broadcaster.publish(.meters(m))
    }

    /// 模拟拔掉一个手柄
    public func simulateDisconnect(_ id: ControllerID) {
        guard state.controllers.contains(where: { $0.id == id }) else { return }
        state.controllers.removeAll { $0.id == id }
        state.canStart = Self.canStart(state.controllers)
        meters.removeValue(forKey: id)
        publishState()
        broadcaster.publish(.event(.controllerDisconnected(id)))
    }

    // MARK: - 内部

    private func publishState() { broadcaster.publish(.state(state)) }

    private func refreshStatuses() {
        for i in state.controllers.indices {
            let c = state.controllers[i]
            let active = state.running && c.settings.enabled && !c.settings.allLeftToGame
            let name: Bilingual
            if !active {
                name = Bilingual(zh: "—", en: "—")
            } else if !c.settings.vibrationEnabled {
                name = Bilingual(zh: "震动交给游戏", en: "Vibration left to games")
            } else if c.capabilities.hasHD && c.settings.hdEnabled {
                name = Bilingual(zh: "HD 震动（USB）", en: "HD haptics (USB)")
            } else if c.capabilities.isDualSense {
                name = c.link == .bluetooth ? Bilingual(zh: "直接控制（蓝牙）", en: "Direct control (Bluetooth)")
                                            : Bilingual(zh: "直接控制（USB）", en: "Direct control (USB)")
            } else {
                name = Bilingual(zh: "CoreHaptics 震动", en: "CoreHaptics vibration")
            }
            state.controllers[i].status = SessionStatus(isActive: active, engineName: name, error: nil)
            state.controllers[i].randomNow = active && c.settings.source == .massage && c.settings.preset == .random
                ? .knead : nil
            if active && c.capabilities.hasSpeaker && c.settings.speakerEnabled {
                state.controllers[i].latency = LatencyBreakdown(tapCaptureMs: 2.7, marginMs: 6.8,
                                                                controllerOutputMs: 4.0, macOutputMs: 12.0)
                state.controllers[i].audioStats = "IO 128 frames · margin 6.8 ms · underruns 0 · align 0 ms"
            } else {
                state.controllers[i].latency = nil
                state.controllers[i].audioStats = nil
            }
        }
    }

    private static func canStart(_ cs: [ControllerInfo]) -> Bool {
        cs.contains { $0.settings.enabled && !$0.settings.allLeftToGame }
    }

    private static func controllers(for s: Scenario) -> [ControllerInfo] {
        let idle = SessionStatus(isActive: false, engineName: Bilingual(zh: "—", en: "—"), error: nil)
        let dualSenseUSB = ControllerInfo(
            id: "fake-ds-usb", name: "DualSense", link: .usb, battery: Battery(level: 95, charging: true),
            capabilities: Capabilities(isDualSense: true, hasLight: true, hasAdaptiveTriggers: true,
                                       hasHD: true, hasSpeaker: true, canVibrate: true),
            settings: ControllerSettings(), status: idle)
        var bluetoothSettings = ControllerSettings()
        bluetoothSettings.musicMode = .bass
        let dualSenseBT = ControllerInfo(
            id: "fake-ds-bt", name: "DualSense", link: .bluetooth, battery: Battery(level: 40, charging: false),
            capabilities: Capabilities(isDualSense: true, hasLight: true, hasAdaptiveTriggers: true,
                                       hasHD: false, hasSpeaker: false, canVibrate: true),
            settings: bluetoothSettings, status: idle)
        var massage = ControllerSettings()
        massage.source = .massage
        massage.preset = .pound
        let eightBitDo = ControllerInfo(
            id: "fake-8bitdo", name: "Pro Controller", link: nil, battery: Battery(level: 30, charging: false),
            capabilities: Capabilities(isDualSense: false, hasLight: false, hasAdaptiveTriggers: false,
                                       hasHD: false, hasSpeaker: false, canVibrate: true),
            settings: massage, status: idle)
        switch s {
        case .none: return []
        case .singleUSB, .captureDenied: return [dualSenseUSB]
        case .multi: return [dualSenseUSB, dualSenseBT, eightBitDo]
        }
    }
}
