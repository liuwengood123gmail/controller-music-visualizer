import SwiftUI

@main
struct ControllerMusicVisualizerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Controller Music Visualizer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(width: 440)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 写入 UserDefaults，L() / Bilingual 读取同一个键；变化时整个界面重绘
    @AppStorage(Language.storageKey) private var language = Language.systemDefault.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let session = model.selected {
                SessionPanel(session: session, running: model.running, language: language)
                    .id(session.id)
            }
            if let notice = model.notice {
                Label(notice.text, systemImage: "lock.shield").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = model.errorMessage {
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
            Button(action: model.toggle) {
                Label(model.running ? L("停止", "Stop") : L("开始", "Start"),
                      systemImage: model.running ? "stop.fill" : "play.fill")
                    .frame(width: 64)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(model.running ? .red : .accentColor)
            .disabled(!model.running && !model.canStart)
        }
    }

    /// 只有一个手柄时直接显示文字（不出现下拉箭头）；多个手柄时用下拉框选择要编辑的手柄
    @ViewBuilder private var controllerChooser: some View {
        if model.sessions.count > 1 {
            Picker("", selection: $model.selectedID) {
                ForEach(model.sessions) { s in
                    Text(s.settings.enabled ? s.title : s.title + L("（未启用）", " (off)"))
                        .tag(Optional(s.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        } else if let s = model.selected {
            HStack(spacing: 6) {
                Text([s.deviceName, s.linkText?.text].compactMap { $0 }.joined(separator: " · ")).font(.headline)
                if let b = s.battery {
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
        guard let s = model.selected else { return L("未运行", "Stopped") }
        if model.running { return s.isActive ? s.engineName.text : L("未启用", "Not enabled") }
        if !model.canStart && !model.sessions.isEmpty { return L("没有启用的手柄", "No controller enabled") }
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

/// 选中手柄的全部设置：绑定到这个会话自己的设置（D2）
struct SessionPanel: View {
    @ObservedObject var session: ControllerSession
    let running: Bool
    let language: String

    private var labelWidth: CGFloat { language == Language.zh.rawValue ? 76 : 116 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle(L("启用这个手柄", "Enable this controller"), isOn: $session.settings.enabled)
                Spacer()
                if session.isActive {
                    Text(session.engineName.text).font(.caption).foregroundStyle(.secondary)
                }
            }

            Group {
                Picker("", selection: $session.settings.source) {
                    ForEach(Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch session.settings.source {
                    case .music: musicPanel
                    case .massage: massagePanel
                    }
                }
                .frame(minHeight: 150, alignment: .top)

                Divider()
                featuresPanel
                Divider()
                meters
            }
            .disabled(!session.settings.enabled)
            .opacity(session.settings.enabled ? 1 : 0.5)

            if let err = session.errorMessage {
                Text(err.text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var musicPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("模式", "Mode"), selection: $session.settings.musicMode) {
                ForEach(MusicMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            slider(L("强度", "Intensity"), value: $session.settings.intensity, in: 0...3)
            slider(L("响应速度", "Response"), value: $session.settings.responsiveness)
            if session.settings.musicMode == .beat {
                slider(L("鼓点灵敏度", "Beat sensitivity"), value: $session.settings.sensitivity)
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
                    Button { session.settings.preset = p } label: {
                        VStack(spacing: 4) {
                            Image(systemName: p.icon).font(.title3)
                            Text(p.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(session.settings.preset == p ? .accentColor : .secondary)
                }
            }
            if session.settings.preset == .random, running, let now = session.randomNow {
                Label(L("随机轮播 · 正在播放：", "Random · now playing: ") + now.title, systemImage: "shuffle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            slider(L("强度", "Intensity"), value: $session.settings.intensity, in: 0...3)
            HStack {
                Text(L("速度", "Speed")).frame(width: labelWidth, alignment: .leading)
                Slider(value: $session.settings.speed, in: 0.5...2)
                Text(String(format: "%.1f×", session.settings.speed)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// 按手柄能力隐藏不支持的设置项（D8）
    private var featuresPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.canVibrate {
                Toggle(L("App 控制震动", "App controls vibration"), isOn: $session.settings.vibrationEnabled)
                if session.settings.vibrationEnabled && session.hasHD {
                    Toggle(L("HD 震动（仅 USB，更细腻）", "HD haptics (USB only, finer detail)"),
                           isOn: $session.settings.hdEnabled)
                        .padding(.leading, 20)
                }
            } else {
                Text(L("此模式不支持震动。8BitDo 请切到 S 模式。", "Vibration is not supported in this mode. For 8BitDo, switch to S mode."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if session.hasAdaptiveTriggers {
                Toggle(L("App 控制扳机（阻尼 · R2 加强 / L2 减弱）", "App controls triggers (resistance · R2 up / L2 down)"),
                       isOn: $session.settings.triggersEnabled)
                if session.settings.triggersEnabled {
                    slider(L("扳机阻尼", "Trigger resistance"), value: $session.settings.triggerResistance)
                        .padding(.leading, 20)
                }
            } else {
                Toggle(L("App 控制 L2 / R2（R2 加强 / L2 减弱）", "App controls L2 / R2 (R2 up / L2 down)"),
                       isOn: $session.settings.triggersEnabled)
            }
            if session.hasLight {
                Toggle(session.settings.source == .music ? L("App 控制灯光（跟随音乐）", "App controls lights (follow music)")
                                                         : L("App 控制灯光（按摩颜色）", "App controls lights (massage color)"),
                       isOn: $session.settings.lightEffects)
                if session.settings.lightEffects {
                    Group {
                        if session.settings.source == .music {
                            slider(L("灯条速度", "Light speed"), value: $session.settings.lightSpeed)
                        }
                        slider(L("灯条起伏", "Light range"), value: $session.settings.lightRange)
                    }
                    .padding(.leading, 20)
                }
            }
            if session.hasSpeaker {
                Toggle(L("手柄扬声器同步播放（仅 USB）", "Play on controller speaker too (USB only)"),
                       isOn: $session.settings.speakerEnabled)
                if session.settings.speakerEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        slider(L("扬声器音量", "Speaker volume"), value: $session.settings.speakerVolume)
                        if let latency = session.latency {
                            Text(latencyText(latency)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let stats = session.audioStats {
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

    /// 只显示当前选中手柄的电平（D6）
    private var meters: some View {
        VStack(spacing: 6) {
            meter("L", session.level.0)
            meter("R", session.level.1)
        }
    }

    private func meter(_ label: String, _ v: Float) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).frame(width: 14)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(width: g.size.width * CGFloat(v))
                }
            }
            .frame(height: 8)
        }
    }

    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float> = 0...1) -> some View {
        HStack {
            Text(title).frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}
