# 设计说明 · Design notes

README 的技术细节部分。更深入的设计见 [multi-controller-design.md](multi-controller-design.md)（多手柄）、[controller-speaker-design.md](controller-speaker-design.md)（手柄扬声器）、[cross-platform-design.md](cross-platform-design.md)（Windows / Android）。

## 整体结构 · Architecture

```
System audio ─► capture (macOS: Core Audio tap · Android: AudioPlaybackCapture)
                  │
                  ▼
ControllerCore (Swift, platform-independent; macOS / Linux / Android)
  MusicAnalyzer ─► raw features + low-frequency waveform + speaker feed  (one per app)
  SessionEngine (per controller, every 10 ms) ─► motors / HD / triggers / light bar / player LEDs
  DualSenseOutputController ─► HID output reports      ControllerAudioRenderer ─► 4-ch audio (speaker + HD)
  SessionReconciler · settings / patches · EngineAPI (ControllerEngine) · FakeControllerEngine
                  │
                  ▼
Platform shells: device discovery, HID send, audio device, UI
  macOS   Sources/ControllerMusicVisualizer  (IOKit HID, AUHAL, GameController, SwiftUI)
  Android android/  (UsbManager / VibratorManager / LightsManager, AAudio or USB isochronous, Compose; core via JNI → ControllerCAPI)
```

- 系统声音只采集、分析一份，交给每个手柄的会话；会话按自己的设置做平滑、鼓点判定、灯条换色，再发给各自的输出通道。· Audio is captured and analyzed once; every controller session applies its own settings and drives its own outputs.
- 界面只通过 `ControllerEngine` 接口和引擎打交道：命令（开始 / 停止 / 设置补丁）、状态快照、约 30Hz 电平、一次性事件。界面开发可以用假引擎（macOS `--fake-engine`，Android 右上角 ⋮）。· The UI talks to the engine only through `ControllerEngine` (commands, state snapshots, ~30 Hz meters, events); a fake engine needs no controller.

## 为什么直接发 HID 报告 · Why raw HID reports

- macOS 只允许**前台** App 通过 GameController 设置扳机阻尼和灯条，进入后台后系统会重置并不断覆盖。直接发 HID 输出报告（USB 0x02 / 蓝牙 0x31 + CRC32）前后台效果一致。· macOS only lets the foreground app set triggers and the light bar via GameController; raw HID reports work in the background too.
- 震动、扳机、灯条、白灯合在一份报告里；状态不变时每 0.1 秒重发一次，盖掉系统的重置。格式参考 Linux `hid-playstation`。· One combined report, resent every 0.1 s; layout follows Linux `hid-playstation`.
- 打不开 HID 设备时退回 GameController + CoreHaptics（手柄的震动服务不支持 `CHHapticAdvancedPatternPlayer`）。· Falls back to GameController + CoreHaptics.

## HD 震动 · HD haptics

- DualSense 是音圈马达：**HD 震动**直接送波形；**兼容震动**只给左右各一个 0–255 强度，由固件模拟转子马达。· Voice-coil actuators: HD = raw waveforms; compatible rumble = one 0–255 strength per side.
- USB 时手柄是 4 声道音频设备，第 3/4 声道驱动左右马达；但 HID 报告里的兼容震动开关（flag0 bit0–1，新固件 flag2 bit2）开着时会忽略这两个声道。本项目自己发报告关掉开关，停止时恢复。· Over USB, channels 3/4 drive the actuators once the compatible-rumble bits are cleared; restored on stop.
- **跟随音乐**：取 300Hz 以下的波形（底鼓、贝斯），按包络归一后软饱和；低频不足时混入正弦载波。系统声音和手柄是两个独立时钟，用环形缓冲把延迟维持在约 20ms。· Music: the <300 Hz waveform, envelope-normalized and soft-saturated, with a sine carrier blended in; a ring buffer bridges the two clocks (~20 ms).
- **频率随强度变化**：马达在 50–65Hz 最有劲，低于 50Hz 变弱；弱时用高频（细腻），强时降到 50–55Hz。· Carrier frequency drops toward 50–55 Hz as intensity rises.
- **蓝牙 HD**：PS5 用私有 0x32 报告传 3kHz 波形（[SAxense](https://github.com/egormanga/SAxense)）。macOS 上每次发送阻塞约 26–30ms，只有所需速率的三分之一，做不了（[bluetooth-audio-research.md](bluetooth-audio-research.md)）。· Not feasible on macOS (send rate too low).

## 相对强度 · Relative loudness

流行音乐混音被压得很平，用「当前 / 最近最大值」会一直满格。所以震动（低音 / 包络）和白点用 `RelativeLevel`：按分贝记住近 2 秒的最小、最大值，把当前音量映射到两者之间，两端至少相差 6dB。· `RelativeLevel` maps loudness between the ~2 s min/max (in dB, ≥ 6 dB apart) so compressed masters don't sit at full.

## 灯条 · Light bar

参考 [audio-reactive-led-strip](https://github.com/scottlawsonbc/audio-reactive-led-strip) 的 energy 效果。· Inspired by its *energy* effect.

- **颜色**：低频（<250Hz）→ 红，中频（250–2500Hz）→ 绿，高频（>2500Hz）→ 蓝，按能量混合，每段按自己的峰值归一并去掉部分共同成分提高饱和度。· Low/mid/high bands → R/G/B.
- **亮度**跟随低音，鼓点间暗下去。**离散换色**：亮着时锁色，亮度低于 12% 再超过 25% 时换色；慢速下连续亮 2 秒就在下一个波谷换色。· Brightness follows the bass; color is re-picked only after it dims.
- 试过按音色重心、最突出频段、和弦识别定颜色：前两者感觉不到和音乐的关系，和弦识别延迟 0.5 秒以上且不准。· Centroid / dominant band / chord recognition were tried and dropped.

## 源码 · Source map

| 位置 · Path | 内容 · Contents |
|---|---|
| `Sources/ControllerCore/` | 平台无关核心：`MusicAnalyzer`、`Shaping`、`MassagePatterns`、`SessionEngine`、`DualSenseReport` / `DualSenseOutputController`、`ControllerAudioRenderer` / `SpeakerDSP` / `Latency` / `HapticWaveform`、`ControllerSettings` / `SettingsPatch` / `ControllerIdentity` / `SessionReconciler`、`EngineAPI` / `FakeControllerEngine` |
| `Sources/ControllerCAPI/` | 核心的 C 接口（`@_cdecl` + JSON），Android 经 JNI 调用 |
| `Sources/ControllerMusicVisualizer/` | macOS：`AppModel`（引擎）、`ControllerSession` / `ControllerRegistry`、`DualSenseHID`（IOKit）、`HDHaptics`（AUHAL）、`SystemAudioTap`、`HapticEngines`（GameController 后备）、`App`（SwiftUI） |
| `android/` | `engine-api`（Kotlin 接口）、`engine-fake`、`ui`（Compose）、`engine`（真实引擎 + `cv_jni.c` / `usb_audio.c`）、`app` |
| `contract/fixtures/` | Swift / Kotlin 共用的契约样例 |
