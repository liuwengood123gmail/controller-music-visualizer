import SwiftUI

@main
struct DualSenseHapticsApp: App {
    @StateObject private var haptics = HapticsController()

    var body: some Scene {
        Window("DualSense Haptics", id: "main") {
            ContentView()
                .environmentObject(haptics)
                .frame(width: 440)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var h: HapticsController
    /// 写入 UserDefaults，L() / Bilingual 读取同一个键；变化时整个界面重绘
    @AppStorage(Language.storageKey) private var language = Language.systemDefault.rawValue

    private var labelWidth: CGFloat { language == Language.zh.rawValue ? 76 : 116 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("", selection: $h.source) {
                ForEach(Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch h.source {
                case .music: musicPanel
                case .massage: massagePanel
                }
            }
            .frame(minHeight: 150, alignment: .top)

            Divider()
            featuresPanel
            Divider()

            meters
            if let notice = h.notice {
                Label(notice.text, systemImage: "lock.shield").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = h.errorMessage {
                Text(err.text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.status.text).font(.headline)
                Text(h.running ? h.engineName.text : L("未运行", "Stopped")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $language) {
                ForEach(Language.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(action: h.toggle) {
                Label(h.running ? L("停止", "Stop") : L("开始", "Start"),
                      systemImage: h.running ? "stop.fill" : "play.fill")
                    .frame(width: 64)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(h.running ? .red : .accentColor)
        }
    }

    private var musicPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("模式", "Mode"), selection: $h.musicMode) {
                ForEach(MusicMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            slider(L("强度", "Intensity"), value: $h.intensity, in: 0...2)
            slider(L("响应速度", "Response"), value: $h.responsiveness)
            if h.musicMode == .beat {
                slider(L("鼓点灵敏度", "Beat sensitivity"), value: $h.sensitivity)
            }
            Text(L("左声道 → 左马达，右声道 → 右马达。响应速度只影响震动。",
                   "Left channel → left motor, right → right. Response only affects vibration."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var massagePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(MassagePreset.allCases) { p in
                    Button { h.preset = p } label: {
                        VStack(spacing: 4) {
                            Image(systemName: p.icon).font(.title3)
                            Text(p.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(h.preset == p ? .accentColor : .secondary)
                }
            }
            slider(L("强度", "Intensity"), value: $h.intensity, in: 0...2)
            HStack {
                Text(L("速度", "Speed")).frame(width: labelWidth, alignment: .leading)
                Slider(value: $h.speed, in: 0.5...2)
                Text(String(format: "%.1f×", h.speed)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var featuresPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider(L("扳机阻尼", "Trigger resistance"), value: $h.triggerResistance)
            Toggle(L("用扳机调强度（R2 加强 · L2 减弱）", "Triggers adjust intensity (R2 up · L2 down)"),
                   isOn: $h.triggerAdjustsIntensity)
            Toggle(h.source == .music ? L("灯条跟随音乐", "Light bar follows music")
                                      : L("灯条显示按摩颜色", "Light bar shows massage color"),
                   isOn: $h.lightEffects)
            if h.lightEffects {
                if h.source == .music {
                    slider(L("灯条速度", "Light speed"), value: $h.lightSpeed)
                }
                slider(L("灯条起伏", "Light range"), value: $h.lightRange)
            }
        }
    }

    private var meters: some View {
        VStack(spacing: 6) {
            meter("L", h.level.0)
            meter("R", h.level.1)
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
