# Controller Music Visualizer

**手柄 · 震动 · 音乐可视化 · 手柄按摩 · PS5 / PS4 手柄 · Mac / Android**

> **让吃灰的手柄，变成你感受音乐的新方式。** 正在播放的任何声音，都能在手里**摸得到**（马达跟着节奏震动），在眼前**看得见**（灯条随乐器变色、白灯随音量跳动）。
>
> **Turn the controller gathering dust into a new way to feel music.** Whatever is playing becomes something you can **feel** (motors pulse with the rhythm) and **see** (the light bar follows the instruments, the white LEDs bounce with the volume).

<p align="center"><img src="docs/screenshot-en.png" width="440" alt="Controller Music Visualizer — English UI"></p>

## 功能 · Features

- **跟随音乐震动**：旁听系统声音（不影响播放），左右声道分别驱动左右马达；三种模式：**节拍**（鼓点）、**低音**（低频起伏）、**包络**（整体音量）。· **Music-driven vibration** from system audio (playback untouched), left/right channels → left/right motors; **Beat**, **Bass** and **Envelope** modes.
- **按摩**：13 种预设 + 随机轮播。· **Massage**: 13 presets plus a random rotation.
- **HD 震动**（USB DualSense）：像 PS5 一样用波形驱动马达，底鼓、贝斯的真实波形传到手上。· **HD haptics** over USB: real kick/bass waveforms reach your hands.
- **手柄扬声器同步播放**（USB DualSense）：Mac / 手机照常放，手柄扬声器同步出声。· **Controller speaker** plays along (USB DualSense).
- **扳机阻尼**；**R2 加强 / L2 减弱**强度。· **Trigger resistance**; **R2 / L2** adjust intensity.
- **灯条**按低 / 中 / 高频混成红 / 绿 / 蓝；**白点**做左右电平表。· **Light bar** colors by frequency band; **player LEDs** as a stereo meter.
- **边玩游戏边用**：震动、扳机、灯光可以分别交给游戏。· **While gaming**: hand vibration, triggers or lights back to the game individually.
- **多手柄**同时用、各自设置，插拔自动识别并记住设置；中英文界面。· **Multiple controllers**, each with its own remembered settings; Chinese / English UI.

## 平台与手柄 · Platforms & controllers

| | macOS 14.2+ | Android 10+（预览版 · preview） |
|---|---|---|
| DualSense **USB** | 全部功能 · everything | 授权「USB 直连」后：震动、扳机阻尼、灯条、白灯、**HD 震动、扬声器** · after granting *USB direct*: everything incl. HD + speaker |
| DualSense **蓝牙 · Bluetooth** | 震动、扳机阻尼、灯条、白灯（无 HD / 扬声器）· all but HD / speaker | 系统兼容震动 + 灯条（Android 12+），无扳机阻尼 / HD / 扬声器 · compatible rumble + light bar only |
| DualShock 4 等其他手柄 · others | 震动（GameController）· rumble | 震动（Android 12+）· rumble |
| 8BitDo Lite 2（S 模式）| 震动（偏弱）· rumble (weak) | 未实测 · untested |

已实测：macOS — DualSense（USB / 蓝牙）、8BitDo Lite 2；Android — 联想拯救者 Y700 二代（Android 15）、红米 Note 13 Pro+（Android 14），DualSense USB / 蓝牙。· Tested devices as listed.

## 安装 · Install

**macOS**

```bash
git clone https://github.com/liuwengood123gmail/controller-music-visualizer.git
cd controller-music-visualizer
./build.sh --install          # 打包并安装到「应用程序」· build and install to /Applications
```

**Android**：在 [Releases → android-preview](https://github.com/liuwengood123gmail/controller-music-visualizer/releases/tag/android-preview) 下载 `ControllerMusicVisualizer-android.apk` 安装（每次推送自动更新）。本机编译、小米机型的装法见 [docs/android.md](docs/android.md)。· Download the APK from the *android-preview* release; local builds and Xiaomi notes in [docs/android.md](docs/android.md).

## 使用 · Usage

1. **连接手柄**：USB 直接插；蓝牙首次配对同时按住 **Create + PS** 3–5 秒，灯条快速双闪后在系统蓝牙设置里连接。· **Connect**: plug in, or hold **Create + PS** for 3–5 s to pair over Bluetooth.
2. 多个手柄时在左上角选择要设置的手柄；取消「启用这个手柄」则 App 完全不碰它。· Pick a controller at the top left; uncheck *Enable* to leave it alone.
3. 点 **开始**。第一次跟随音乐时系统会请求权限：macOS「系统录音」，Android「屏幕录制」（只读声音）。· Press **Start**; allow *System Audio Recording* (macOS) or *screen capture* (Android, audio only).

| 设置 · Setting | 作用 · What it does |
|---|---|
| 强度 · Intensity | 0–300%；超过 100% 抬高弱震动 · above 100% lifts weak vibration |
| 响应速度 · Response | 震动跟随声音的快慢 · how fast vibration follows the audio |
| 鼓点灵敏度 · Beat sensitivity | 节拍模式下越高越小的鼓点也触发 · Beat mode only |
| App 控制震动 / 扳机 / 灯光 · App controls … | 取消即交给游戏 · off = left to the game |
| HD 震动 · HD haptics | 仅 USB；关闭则用兼容震动 · USB only |
| 扳机阻尼 · Trigger resistance | L2/R2 阻力，0 为关 · 0 = off |
| 灯条速度 / 起伏 · Light speed / range | 暗下去的快慢 / 亮暗幅度 · dimming speed / depth |
| 扬声器音量 · Speaker volume | 仅 USB DualSense · USB DualSense only |

设置按手柄分别记住；新手柄复制当前选中手柄的设置；没有的能力不显示。· Settings are per controller; new controllers copy the selected one's.

**提示 · Tips**：想要跟得紧、强弱明显，用低音或包络模式、响应速度 90–100%。边玩游戏边用：「跟随音乐 → 低音」，取消「App 控制扳机」保留游戏的自适应扳机。· For punchy vibration use Bass/Envelope with Response 90–100%; while gaming, use Bass and hand the triggers back to the game.

**macOS 屏蔽 PS 键**：App 在前台时 PS 键不再打开系统「游戏」；要全局屏蔽，到「系统设置 → 游戏控制器 → Home Button」关闭 *Enable Home Button Actions*。· The PS button is blocked while the app is in front; to block it everywhere, turn off *Enable Home Button Actions* in System Settings.

## 已知限制 · Known limitations

- HD 震动和扬声器只支持 USB；蓝牙是兼容震动（macOS 蓝牙速率不够，Android 16 及以下 App 拿不到蓝牙 HID）。· HD / speaker are USB only.
- Android 只能读到允许被录制的 App 的声音；蓝牙兼容震动比 Mac 弱，灯光更新频率较低（太频繁会拖弱震动）。· Android captures only apps that allow it; Bluetooth rumble is weaker and the light bar updates less often.
- 系统音量不影响震动（采集的是调音量之前的声音）；灯条是一颗 RGB 灯，不能分左右。· System volume doesn't affect vibration; the light bar is a single RGB LED.

## 开发 · Development

- 测试：`swift test`（不需要手柄）；CI 在 macOS、Linux（`ControllerCore`）和 Android（交叉编译 + 模拟器测试）上跑。· Tests: `swift test`; CI covers macOS, Linux and Android.
- 调试参数（macOS）：`--autostart`、`--massage`、`--select <n>`、`--fake-engine [none|singleUSB|multi|captureDenied]`。· macOS debug flags.
- 扬声器可调参数（macOS）：`defaults write com.liuliu.ControllerMusicVisualizer speaker.<键> <值>`，键有 `hwVolume`（默认 100）、`preamp`（2）、`highpassHz`（200）、`bufferMs`（自动）、`ioFrames`（128）、`tapFrames`（128）、`hapticsDelayMs`（自动）。· Speaker tuning keys.
- 文档：[设计说明](docs/design-notes.md) · [Android](docs/android.md) · [多手柄](docs/multi-controller-design.md) · [手柄扬声器](docs/controller-speaker-design.md) · [跨平台设计](docs/cross-platform-design.md) · [蓝牙音频调研](docs/bluetooth-audio-research.md)
