# DualSense Haptics

> **让吃灰的手柄，变成你感受音乐的新方式。**
> 插上（或蓝牙连上）一只索尼手柄，Mac 上正在播放的任何音乐，都能在手里**摸得到**（左右马达跟着节奏震动），在眼前**看得见**（灯条随乐器变色、白灯随音量跳动）。
>
> **Turn the controller gathering dust into a new way to experience music.**
> Connect a Sony controller over USB or Bluetooth, and whatever is playing on your Mac becomes something you can **feel** — the left and right motors pulse with the rhythm — and **see** — the light bar shifts color with the instruments and the white LEDs bounce with the volume.

适用于大部分索尼手柄：DualSense / DualSense Edge 支持全部功能，DualShock 4 等其他手柄也能用上震动（详见[支持的手柄](#支持的手柄--supported-controllers)）。跟随音乐之外，还内置按摩效果和扳机阻尼。

Works with most Sony controllers: DualSense / DualSense Edge get every feature, and DualShock 4 and other controllers still get vibration (see [Supported controllers](#支持的手柄--supported-controllers)). Beyond music, it also has massage patterns and adaptive-trigger resistance.

---

## 功能 · Features

| 中文 | English |
|---|---|
| **跟随音乐震动**：旁听系统正在播放的声音（不影响原有播放），左声道驱动左马达、右声道驱动右马达 | **Music-driven vibration**: listens to system audio (without affecting playback); left channel → left motor, right → right |
| 三种震动模式：**节拍**（鼓点脉冲）、**低音**（跟随低频起伏）、**包络**（跟随整体音量起伏） | Three modes: **Beat** (pulses on drum hits), **Bass** (follows low frequencies), **Envelope** (follows overall loudness) |
| **按摩**：揉捏、敲击、拍打、指压、波浪、心跳、渐强、随机 8 种预设 | **Massage**: 8 presets — Knead, Tap, Pat, Shiatsu, Wave, Heartbeat, Crescendo, Random |
| **扳机阻尼**：L2/R2 可调阻力，App 在后台时依然有效 | **Trigger resistance**: adjustable L2/R2 resistance that keeps working while the app is in the background |
| **扳机调强度**：按 R2 加强、L2 减弱，按得越深变得越快 | **Trigger intensity control**: hold R2 to increase, L2 to decrease; deeper press = faster change |
| **灯条**：低/中/高频混合成红/绿/蓝，亮度跟随低音节奏，暗下去之后才换色 | **Light bar**: low/mid/high frequencies mixed into red/green/blue, brightness pulses with the bass, color changes only after it dims |
| **白点电平灯**：下方 5 颗白灯显示左右声道的相对强度 | **Player LEDs**: the 5 white LEDs act as a stereo level meter |
| USB 和蓝牙都支持；界面中英文切换 | Works over USB and Bluetooth; Chinese / English UI |

## 支持的手柄 · Supported controllers

| 手柄 · Controller | 支持情况 · Support |
|---|---|
| **DualSense（PS5）**、**DualSense Edge** | ✅ 全部功能：震动、扳机阻尼、灯条、白点电平灯，App 在后台也有效；USB / 蓝牙均可 · ✅ Everything: vibration, trigger resistance, light bar, player LEDs — also while the app is in the background; USB or Bluetooth |
| 以索尼 DualSense 身份被系统识别的兼容手柄 · Third-party controllers that identify as a Sony DualSense | ✅ 与 DualSense 相同 · ✅ Same as DualSense |
| **DualShock 4（PS4）** 及其他 macOS 能识别、支持震动的手柄 · **DualShock 4 (PS4)** and other controllers macOS recognizes with rumble | ⚠️ 基本功能：通过 GameController 震动；DualShock 4 的灯条在 App 位于前台时可变色；没有扳机阻尼和白点电平灯 · ⚠️ Basics: vibration via GameController; the DualShock 4 light bar changes color while the app is in the foreground; no trigger resistance or player LEDs |

> 已实测：DualSense（USB 和蓝牙）。其他手柄按代码逻辑应可使用，但尚未逐一实测，欢迎反馈。
> Tested: DualSense over USB and Bluetooth. Other controllers should work according to the code paths but haven't each been tested — feedback welcome.

## 环境要求 · Requirements

- macOS 14.2 或更高版本（系统声音采集接口需要）· macOS 14.2 or later (required for the system-audio tap API)
- 一只索尼手柄（推荐 DualSense / DualSense Edge），USB 或蓝牙连接 · A Sony controller (DualSense / DualSense Edge recommended), connected via USB or Bluetooth
- Xcode 命令行工具（Swift 5.10+）· Xcode Command Line Tools (Swift 5.10+)

## 编译运行 · Build & Run

```bash
git clone https://github.com/liuwengood123gmail/DualSenseHaptics.git
cd DualSenseHaptics
./build.sh
open build/DualSenseHaptics.app
```

`build.sh` 会编译并打包成 `build/DualSenseHaptics.app`。本机有 Apple Development 证书时会用它签名（这样重新编译后系统录音权限不会丢失），否则使用临时签名。

`build.sh` compiles the app and packages it as `build/DualSenseHaptics.app`. If an Apple Development certificate is available it is used for signing (so the audio permission survives rebuilds); otherwise the app is ad-hoc signed.

## 使用方法 · Usage

1. **连接手柄** · **Connect the controller**
   - USB：插上数据线即可。· USB: just plug it in.
   - 蓝牙：首次配对时同时按住 **Create** 和 **PS** 键约 3–5 秒，灯条快速双闪后，在「系统设置 → 蓝牙」里连接。之后按一下 PS 键即可重连。· Bluetooth: for first-time pairing, hold **Create** + **PS** for 3–5 s until the light bar double-flashes, then connect in System Settings → Bluetooth. Afterwards, press PS to reconnect.
2. **点「开始」**（或按空格键）。· **Press Start** (or the space bar).
3. **首次使用「跟随音乐」**会请求「系统录音」权限，点「允许」。弹窗可能出现在另一块显示器上。如果错过了，可在「系统设置 → 隐私与安全性 → 录屏与系统录音」里打开。· **The first time you use Music mode**, macOS asks for *System Audio Recording* permission — click Allow. The dialog may appear on another display. If you missed it, enable the app in System Settings → Privacy & Security → Screen & System Audio Recording.

### 控制项说明 · Controls

| 控制项 | 作用 | Control | What it does |
|---|---|---|---|
| 强度 | 0–200%。超过 100% 会抬高弱震动，但强弱对比会变小 | Intensity | 0–200%. Above 100% lifts weak vibration but reduces contrast |
| 响应速度 | 震动跟随声音的快慢（尤其是声音变小时） | Response | How quickly vibration follows the audio (especially when it gets quieter) |
| 鼓点灵敏度 | 仅节拍模式：越高，越小的鼓点也会触发 | Beat sensitivity | Beat mode only: higher = softer hits also trigger |
| 速度 | 按摩节奏快慢 | Speed | Massage tempo |
| 扳机阻尼 | L2/R2 阻力，0 为关闭 | Trigger resistance | L2/R2 resistance; 0 = off |
| 灯条速度 | 灯条暗下去的快慢：慢像呼吸灯，快则一闪一闪；也决定换色频率 | Light speed | How fast the light bar dims: slow = breathing, fast = flashing; also sets how often colors change |
| 灯条起伏 | 亮暗变化幅度：100% 时鼓点间完全暗掉，越低保留的底亮度越高 | Light range | Depth of the pulsing: 100% = fully dark between beats, lower keeps a base glow |

**建议 · Tips**：想要「跟得紧、强弱明显」，选低音或包络模式，响应速度 90–100%，强度 100% 左右。· For tight, punchy vibration, use Bass or Envelope mode, Response at 90–100%, Intensity around 100%.

## 设计思路 · Design

### 整体结构 · Architecture

```
系统声音 System audio ──► SystemAudioTap ──► MusicAnalyzer ──┐
   (Core Audio process tap，只旁听 / listen-only)              ├─► HapticsController ──► DualSenseHID ──► 手柄 Controller
                         MassagePreset（按摩波形 / patterns）──┘        (每 10ms / every 10 ms)     (震动 + 扳机 + 灯光 / rumble + triggers + lights)
                                        GameController ──► 读取扳机按压 / read trigger pressure
```

| 文件 · File | 职责 · Responsibility |
|---|---|
| `SystemAudioTap.swift` | 用 Core Audio process tap 旁听整机声音（`muteBehavior = unmuted`，不影响播放）· Listens to all system audio via a Core Audio process tap (unmuted; playback is untouched) |
| `MusicAnalyzer.swift` | 滤波、相对强度、鼓点检测，输出震动强度和灯光特征 · Filtering, relative loudness, beat detection; outputs vibration and light features |
| `MassagePatterns.swift` | 8 种按摩波形和颜色 · The 8 massage waveforms and colors |
| `DualSenseHID.swift` | 直接发送 HID 输出报告（USB 0x02 / 蓝牙 0x31 + CRC32）· Sends raw HID output reports (USB 0x02 / Bluetooth 0x31 + CRC32) |
| `HapticEngines.swift` | 后备方案：GameController + CoreHaptics · Fallback path: GameController + CoreHaptics |
| `HapticsController.swift` | 主循环、引擎选择、灯光映射 · Main loop, engine selection, light mapping |
| `App.swift` / `Localization.swift` | SwiftUI 界面、中英文切换 · SwiftUI UI and Chinese/English switching |

### 为什么直接发 HID 报告 · Why raw HID reports

- macOS 只允许**前台** App 通过 GameController 设置扳机阻尼和灯条；App 进入后台后系统会重置它们，并用自己的输出报告不断覆盖。直接向手柄发送 HID 输出报告可以绕开这个限制，前台后台效果一致。
- macOS only lets the **foreground** app set trigger effects and the light bar through GameController; when the app goes to the background the system resets them and keeps overwriting them. Sending HID output reports directly avoids this, so behavior is the same in the foreground and background.
- 震动、扳机、灯条、白灯合在一份报告里发送；状态不变时每 0.1 秒重发一次，盖掉系统的重置。报告格式参考 Linux `hid-playstation` 驱动。
- Rumble, triggers, light bar and player LEDs share one report; it is resent every 0.1 s even when unchanged to override system resets. The report layout follows the Linux `hid-playstation` driver.
- 如果打不开 HID 设备，会退回 GameController + CoreHaptics（注意：手柄的震动服务不支持 `CHHapticAdvancedPatternPlayer`，只能用普通 player 加动态参数）。
- If the HID device can't be opened, the app falls back to GameController + CoreHaptics (note: the controller haptics service rejects `CHHapticAdvancedPatternPlayer`, so a plain player with dynamic parameters is used).

> **关于 HD 震动 · About HD haptics**：USB 连接时 DualSense 会出现一个 4 声道音频设备（第 3/4 声道驱动震动单元，PS5 就是这样做 HD 震动的），但 macOS 驱动没有开启这个模式，写入波形不会震，所以本项目使用兼容震动。
> Over USB the DualSense exposes a 4-channel audio device (channels 3/4 drive the actuators — this is how the PS5 does HD haptics), but the macOS driver doesn't enable that mode, so writing waveforms there does nothing. This project uses compatible rumble instead.

### 相对强度 · Relative loudness

- 流行音乐混音时整体音量被压得很平，如果拿「当前音量 / 最近最大值」来驱动，响的歌会一直满格。
- Modern masters are heavily compressed; driving output by "current / recent peak" keeps loud songs pinned at full.
- 所以震动（低音/包络模式）和白点都使用 `RelativeLevel`：按分贝记住近 2 秒的最小、最大音量，把当前音量映射到两者之间；两端至少相差 6dB，避免微小波动被放大。
- So vibration (Bass/Envelope) and the player LEDs use `RelativeLevel`: it tracks the min and max loudness (in dB) over ~2 s and maps the current level between them, with at least 6 dB of range so tiny fluctuations aren't amplified.

### 灯条 · Light bar

参考了 [audio-reactive-led-strip](https://github.com/scottlawsonbc/audio-reactive-led-strip) 的 energy 效果。· Inspired by the *energy* effect in [audio-reactive-led-strip](https://github.com/scottlawsonbc/audio-reactive-led-strip).

| 中文 | English |
|---|---|
| **颜色**：低频（<250Hz，底鼓/贝斯）→ 红，中频（250–2500Hz，人声/吉他）→ 绿，高频（>2500Hz，镲片）→ 蓝，按能量混合。每段按自己的峰值归一，并去掉一部分共同成分来提高饱和度 | **Color**: low (<250 Hz, kick/bass) → red, mid (250–2500 Hz, vocals/guitar) → green, high (>2500 Hz, cymbals) → blue, mixed by energy. Each band is normalized to its own peak, and part of the common component is removed to boost saturation |
| **亮度**：跟随低音起伏，减去近期底线后放大，鼓点间会暗下去 | **Brightness**: follows the bass envelope minus a recent floor, so it dims between beats |
| **离散换色**：亮着时颜色锁定；亮度低于 12% 算「暗了」，重新超过 25% 时按当时的声音成分选新颜色。慢速下如果连续亮了 2 秒，就在下一个亮度波谷换色 | **Discrete color changes**: the color is locked while lit; it is re-picked from the current sound only after brightness drops below 12% and rises above 25% again. At slow speeds, if it stays lit for 2 s, the color changes at the next brightness trough |

我们也试过「按音色重心」「按最突出频段」「按和弦识别」来定颜色：前两者让人感觉不到和音乐的关系，和弦识别则有 0.5 秒以上的延迟且实时识别不够准，最终选择了上面这种低延迟、能直观对应声音的方式。

We also tried coloring by spectral centroid, by the most prominent band, and by real-time chord recognition. The first two didn't feel connected to the music, and chord recognition lagged by 0.5 s or more and wasn't reliable in real time, so we settled on the low-latency, intuitive mapping above.

## 已知限制 · Known limitations

- 触控板两侧的灯条是同一颗 RGB 灯，无法分别显示左右声道。· The light bar on both sides of the touchpad is a single RGB LED, so it can't show left and right channels separately.
- 震动是兼容震动（强弱），不是 PS5 那种 HD 震动（波形质感）。· Vibration is compatible rumble (intensity only), not PS5-style HD haptics.
- 系统音量键不影响震动：采集到的是系统调音量之前的声音。· The system volume doesn't affect vibration: the tap captures audio before system volume is applied.

## 其他 · Misc

- `dualsense_test.swift`：最早用来测试手柄按键、震动、灯条、自适应扳机的命令行小工具（`swiftc -swift-version 5 dualsense_test.swift -o dualsense_test && ./dualsense_test`）。· A small CLI tool from early development that tests buttons, rumble, light bar and adaptive triggers.
- 调试：`open build/DualSenseHaptics.app --args --autostart` 启动后自动开始。· Debugging: `--autostart` starts output on launch.
