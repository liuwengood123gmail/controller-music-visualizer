import ControllerCore
import SwiftUI

@main
struct ControllerMusicVisualizerApp: App {
    @StateObject private var store: EngineStore

    init() {
        Language.store = UserDefaults.standard   // L() / Bilingual 和下面的 @AppStorage 读同一个键
        // 调试 / 界面开发用：--fake-engine [none|singleUSB|multi|captureDenied] 不连任何设备，用假引擎
        let args = CommandLine.arguments
        let engine: ControllerEngine
        if let i = args.firstIndex(of: "--fake-engine") {
            let name = i + 1 < args.count ? args[i + 1] : ""
            engine = FakeControllerEngine(scenario: FakeControllerEngine.Scenario(rawValue: name) ?? .multi)
        } else {
            engine = AppModel()
        }
        _store = StateObject(wrappedValue: EngineStore(engine: engine))
    }

    var body: some Scene {
        Window("Controller Music Visualizer", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(width: 440)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

/// 界面这一侧的状态：引擎发来的快照 + 只属于界面的「选中哪个手柄」。
/// 界面只通过 `ControllerEngine` 发命令；设置改动都变成 `SettingsPatch`
@MainActor
final class EngineStore: ObservableObject {
    let engine: ControllerEngine
    @Published private(set) var state: EngineState
    @Published var selectedID: ControllerID? {
        didSet { if selectedID != oldValue { engine.focus(selectedID) } }
    }
    /// 电平单独放：约 30Hz 更新，只让电平条重绘
    let meters = MeterStore()
    private var subscription: EngineSubscription?
    private var simulation: Timer?

    init(engine: ControllerEngine) {
        self.engine = engine
        state = engine.state
        subscription = engine.subscribe { [weak self] update in self?.handle(update) }

        // 调试用：--select <序号> 打开时选中第几个手柄（从 0 开始）
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--select"), i + 1 < args.count, let n = Int(args[i + 1]),
           state.controllers.indices.contains(n) {
            selectedID = state.controllers[n].id
        }
        engine.focus(selected?.id)

        // 假引擎没有自己的主循环：由界面推进模拟时间
        if let fake = engine as? FakeControllerEngine {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak fake] _ in
                MainActor.assumeIsolated { fake?.advance(by: 1.0 / 30) }
            }
            RunLoop.main.add(t, forMode: .common)
            simulation = t
        }
    }

    private func handle(_ update: EngineUpdate) {
        switch update {
        case .state(let s):
            if s != state { state = s }
            if !s.controllers.contains(where: { $0.id == selectedID }) { selectedID = s.controllers.first?.id }
        case .meters(let m):
            if m != meters.values { meters.values = m }
        case .event:
            break
        }
    }

    var selected: ControllerInfo? { state.controller(selectedID) ?? state.controllers.first }

    func toggle() { state.running ? engine.stop() : engine.start() }

    /// 改选中手柄的一项设置：算出补丁发给引擎（只含改动的字段）
    func edit(_ id: ControllerID, _ change: (inout ControllerSettings) -> Void) {
        guard let old = state.controller(id)?.settings else { return }
        var new = old
        change(&new)
        let patch = SettingsPatch(from: old, to: new)
        if !patch.isEmpty { engine.updateSettings(id, patch) }
    }

    /// 绑定到某个手柄的一项设置：读引擎快照，写成补丁
    func binding<T>(_ id: ControllerID, _ key: WritableKeyPath<ControllerSettings, T>) -> Binding<T> {
        Binding(
            get: { [weak self] in (self?.state.controller(id)?.settings ?? ControllerSettings())[keyPath: key] },
            set: { [weak self] v in self?.edit(id) { $0[keyPath: key] = v } })
    }

    var blockHomeButton: Binding<Bool> {
        Binding(get: { [weak self] in self?.state.options.blockHomeButton ?? true },
                set: { [weak self] v in self?.engine.setGlobalOptions(GlobalOptionsPatch(blockHomeButton: v)) })
    }
}

@MainActor
final class MeterStore: ObservableObject {
    @Published var values: [ControllerID: Meter] = [:]
}

struct ContentView: View {
    @EnvironmentObject var store: EngineStore
    /// 写入 UserDefaults，L() / Bilingual 读取同一个键；变化时整个界面重绘
    @AppStorage(Language.storageKey) private var language = Language.systemDefault.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let info = store.selected {
                SessionPanel(info: info, running: store.state.running, language: language)
                    .id(info.id)
            }
            Toggle(L("屏蔽 PS 键打开系统「游戏」", "Block the PS button from opening Games"), isOn: store.blockHomeButton)
                .font(.callout)
            if let notice = store.state.notice {
                Label(notice.text, systemImage: "lock.shield").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = store.state.error {
                Text(err.text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                controllerChooser
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $language) {
                ForEach(Language.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(action: store.toggle) {
                Label(store.state.running ? L("停止", "Stop") : L("开始", "Start"),
                      systemImage: store.state.running ? "stop.fill" : "play.fill")
                    .frame(width: 64)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(store.state.running ? .red : .accentColor)
            .disabled(!store.state.running && !store.state.canStart)
        }
    }

    /// 只有一个手柄时直接显示文字（不出现下拉箭头）；多个手柄时用下拉框选择要编辑的手柄
    @ViewBuilder private var controllerChooser: some View {
        if store.state.controllers.count > 1 {
            Picker("", selection: $store.selectedID) {
                ForEach(store.state.controllers) { c in
                    Text(c.settings.enabled ? c.title : c.title + L("（未启用）", " (off)"))
                        .tag(Optional(c.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        } else if let c = store.selected {
            HStack(spacing: 6) {
                Text([c.name, c.link?.title.text].compactMap { $0 }.joined(separator: " · ")).font(.headline)
                if let b = c.battery {
                    Label("\(b.level)%", systemImage: batteryIcon(b.level, charging: b.charging))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(b.level <= 15 && !b.charging ? .red : .secondary)
                        .help(b.charging ? L("充电中", "Charging") : L("电量", "Battery"))
                }
            }
        } else {
            Text(L("未连接手柄", "No controller")).font(.headline)
        }
    }

    private var statusLine: String {
        guard let c = store.selected else { return L("未运行", "Stopped") }
        if store.state.running { return c.status.isActive ? c.status.engineName.text : L("未启用", "Not enabled") }
        if !store.state.canStart && !store.state.controllers.isEmpty { return L("没有启用的手柄", "No controller enabled") }
        return L("未运行", "Stopped")
    }
}

func batteryIcon(_ level: Int, charging: Bool) -> String {
    if charging { return "battery.100percent.bolt" }
    switch level {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

/// 选中手柄的全部设置：显示引擎快照，改动发补丁给这个手柄（D2）
struct SessionPanel: View {
    @EnvironmentObject var store: EngineStore
    let info: ControllerInfo
    let running: Bool
    let language: String

    private var labelWidth: CGFloat { language == Language.zh.rawValue ? 76 : 116 }
    private var settings: ControllerSettings { info.settings }
    private var caps: Capabilities { info.capabilities }
    private func bind<T>(_ key: WritableKeyPath<ControllerSettings, T>) -> Binding<T> { store.binding(info.id, key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle(L("启用这个手柄", "Enable this controller"), isOn: bind(\.enabled))
                Spacer()
                if info.status.isActive {
                    Text(info.status.engineName.text).font(.caption).foregroundStyle(.secondary)
                }
            }

            Group {
                Picker("", selection: bind(\.source)) {
                    ForEach(Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch settings.source {
                    case .music: musicPanel
                    case .massage: massagePanel
                    }
                }
                .frame(minHeight: 150, alignment: .top)

                Divider()
                featuresPanel
                Divider()
                MetersView(meters: store.meters, id: info.id)
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.5)

            if let err = info.status.error {
                Text(err.text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var musicPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("模式", "Mode"), selection: bind(\.musicMode)) {
                ForEach(MusicMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            slider(L("强度", "Intensity"), value: bind(\.intensity), in: 0...3)
            slider(L("响应速度", "Response"), value: bind(\.responsiveness))
            if settings.musicMode == .beat {
                slider(L("鼓点灵敏度", "Beat sensitivity"), value: bind(\.sensitivity))
            }
            Text(L("左声道 → 左马达，右声道 → 右马达。响应速度只影响震动。",
                   "Left channel → left motor, right → right. Response only affects vibration."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var massagePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(MassagePreset.allCases) { p in
                    Button { store.edit(info.id) { $0.preset = p } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: p.icon).font(.title3)
                            Text(p.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(settings.preset == p ? .accentColor : .secondary)
                }
            }
            if settings.preset == .random, running, let now = info.randomNow {
                Label(L("随机轮播 · 正在播放：", "Random · now playing: ") + now.title, systemImage: "shuffle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            slider(L("强度", "Intensity"), value: bind(\.intensity), in: 0...3)
            HStack {
                Text(L("速度", "Speed")).frame(width: labelWidth, alignment: .leading)
                Slider(value: bind(\.speed), in: 0.5...2)
                Text(String(format: "%.1f×", settings.speed)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// 按手柄能力隐藏不支持的设置项（D8）
    private var featuresPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if caps.canVibrate {
                Toggle(L("App 控制震动", "App controls vibration"), isOn: bind(\.vibrationEnabled))
                if settings.vibrationEnabled && caps.hasHD {
                    Toggle(L("HD 震动（仅 USB，更细腻）", "HD haptics (USB only, finer detail)"),
                           isOn: bind(\.hdEnabled))
                        .padding(.leading, 20)
                }
            } else {
                Text(L("此模式不支持震动。8BitDo 请切到 S 模式。", "Vibration is not supported in this mode. For 8BitDo, switch to S mode."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if caps.hasAdaptiveTriggers {
                Toggle(L("App 控制扳机（阻尼 · R2 加强 / L2 减弱）", "App controls triggers (resistance · R2 up / L2 down)"),
                       isOn: bind(\.triggersEnabled))
                if settings.triggersEnabled {
                    slider(L("扳机阻尼", "Trigger resistance"), value: bind(\.triggerResistance))
                        .padding(.leading, 20)
                }
            } else {
                Toggle(L("App 控制 L2 / R2（R2 加强 / L2 减弱）", "App controls L2 / R2 (R2 up / L2 down)"),
                       isOn: bind(\.triggersEnabled))
            }
            if caps.hasLight {
                Toggle(settings.source == .music ? L("App 控制灯光（跟随音乐）", "App controls lights (follow music)")
                                                         : L("App 控制灯光（按摩颜色）", "App controls lights (massage color)"),
                       isOn: bind(\.lightEffects))
                if settings.lightEffects {
                    Group {
                        if settings.source == .music {
                            slider(L("灯条速度", "Light speed"), value: bind(\.lightSpeed))
                        }
                        slider(L("灯条起伏", "Light range"), value: bind(\.lightRange))
                    }
                    .padding(.leading, 20)
                }
            }
            if caps.hasSpeaker {
                Toggle(L("手柄扬声器同步播放（仅 USB）", "Play on controller speaker too (USB only)"),
                       isOn: bind(\.speakerEnabled))
                if settings.speakerEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        slider(L("扬声器音量", "Speaker volume"), value: bind(\.speakerVolume))
                        if let latency = info.latency {
                            Text(latencyText(latency)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let stats = info.audioStats {
                            Text(stats).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            Text(L("取消勾选的项交给游戏控制，方便边玩游戏边用。", "Unchecked items are left to the game, so you can use this while gaming."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 延迟分解的一行小字：手柄比 Mac 音响晚多少，以及各段（采集 + 缓冲余量 + 手柄输出）
    private func latencyText(_ b: LatencyBreakdown) -> String {
        let parts = String(format: "%.0f + %.0f + %.0f ms", b.tapCaptureMs, b.marginMs, b.controllerOutputMs)
        if let extra = b.extraMs {
            return L("手柄比 Mac 音响约晚 \(Int(extra.rounded())) ms（采集 + 缓冲 + 手柄输出 = \(parts)）",
                     "Controller is ~\(Int(extra.rounded())) ms behind the Mac speakers (capture + buffer + output = \(parts))")
        }
        return L("手柄扬声器延迟约 \(Int(b.controllerTotalMs.rounded())) ms（\(parts)）",
                 "Controller speaker delay ~\(Int(b.controllerTotalMs.rounded())) ms (\(parts))")
    }

    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float> = 0...1) -> some View {
        HStack {
            Text(title).frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}

/// 只显示当前选中手柄的电平（D6）。单独观察电平：约 30Hz 更新时只重绘这两条
struct MetersView: View {
    @ObservedObject var meters: MeterStore
    let id: ControllerID

    var body: some View {
        let m = meters.values[id] ?? .zero
        VStack(spacing: 6) {
            meter("L", m.left)
            meter("R", m.right)
        }
    }

    private func meter(_ label: String, _ v: Float) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).frame(width: 14)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(width: g.size.width * CGFloat(min(max(v, 0), 1)))
                }
            }
            .frame(height: 8)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(EngineStore(engine: FakeControllerEngine(scenario: .multi)))
            .frame(width: 440)
    }
}
