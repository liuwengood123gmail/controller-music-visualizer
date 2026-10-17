# Windows / Android 支持 · 调研与设计

> 状态：**调研 + 设计**，尚未实现。目标：在现有 macOS 版的基础上支持 **Windows** 和 **Android 手机 / 平板**，**尽量复用现有代码**。
> 先读 README「设计思路」、[multi-controller-design.md](multi-controller-design.md)、[controller-speaker-design.md](controller-speaker-design.md)、[research/bluetooth-audio-findings.md](research/bluetooth-audio-findings.md)。
> 标记：**[已证实]** 有链接或原文依据；**[推测]** 是推理，需要实物验证；**[待核实]** 来自记忆或二手资料。调研在云端完成，**没有在 Windows / Android 实机上验证任何东西**。

## 0. 结论先行

1. **路线：Swift 核心库 + 各平台原生外壳。** 现有代码里约 **1,300 行纯逻辑**（音乐分析、震动 / 灯光整形、按摩、DualSense 报告构造、设置、身份、扬声器 DSP、延迟模型）只依赖 Foundation，可以原样编译到 Windows 和 Android：Swift 官方支持 Windows，Swift 6.3（2026-03）起有官方 Android SDK。此外有约 **700 行**逻辑目前和 Apple 框架混在一起（分散在约 1,400 行的文件里）（会话的每 10ms 计算、HID 发送状态机、4 声道音频渲染），抽出来以后也能复用。**界面无法复用**（SwiftUI 只有 Apple 平台），每个平台各写一个界面外壳。
2. **Windows 是「全功能」平台**，USB 连接时能做到 macOS 现在的全部功能：
   - **系统声音采集**：WASAPI 环回。
   - **HID 输出**（震动 / 扳机 / 灯光）：Win32 HID，用 `WriteFile`。
   - **HD 震动 + 扬声器**：手柄在 Windows 上同样是 4 声道音频设备，第 1/2 声道 = 扬声器，第 3/4 声道 = 触觉 [社区资料]。
   - **蓝牙**：Windows 下的 HD 震动有社区项目在 Windows 蓝牙下实现过（awalol/dualsense-bt-haptics），**蓝牙限制可能比 macOS 宽松**，需要实测。
3. **Android 分三档**：
   - **A 档（Android 12+，任何手柄）**：系统的 `VibratorManager` / `LightsManager` → 双马达兼容震动 + 灯条颜色 + 玩家指示灯。没有扳机阻尼、HD、扬声器。
   - **B 档（Android 17+ / API 37）**：新的 `HidManager` / `HidDevice` 可以直接给 HID 设备发输出报告，需要用户授予 `ACCESS_HID`（危险级权限）并在系统选择器里选中设备 [已证实，文档]。DualSense 的扳机阻尼、灯条、白灯能**直接复用 `DualSenseReport`**；蓝牙 HD / 扬声器能否到达所需速率**待实测**。
   - **C 档（USB 连接）**：经 AAudio 输出 4 声道 USB 音频做 HD 震动 + 扬声器——Android 的 USB 音频 4 声道支持**不确定**，需要实测。
   - **系统声音采集**：`AudioPlaybackCapture`（Android 10+），需要用户每次同意屏幕录制、开前台服务；**只能采到允许被采集的 App**：用途为媒体 / 游戏 / 未知的音频，且该 App 没有退出采集 [已证实]。
4. **最大的工作量不在新平台，而在第一步重构**：把核心抽成独立的 SwiftPM 目标、把平台相关的部分换成协议，**macOS 行为保持不变**。这一步做完，Windows 和 Android 只需各写一层「采集 / HID / 音频设备 / 界面」。
5. 建议顺序：**P0 重构（macOS 回归）→ P1 Windows USB → P2 Windows 蓝牙 / 其他手柄 → P3 Android A 档 → P4 Android B / C 档**。每一阶段都有可单独交付的产品。

## 1. 现有代码盘点：哪些能复用

`Sources/ControllerMusicVisualizer/` 的 19 个文件按「依赖了什么」分三类（行数为当前 master）：

| 类别 | 文件 | 行数 | 依赖 | 去其他平台要做什么 |
|---|---|---|---|---|
| **纯逻辑，原样复用** | `MusicAnalyzer.swift` | 202 | Foundation、`os`（`OSAllocatedUnfairLock`） | 把锁换成跨平台实现（§5.4），其余不动 |
| | `Shaping.swift` | 126 | Foundation | 无 |
| | `MassagePatterns.swift` | 262 | Foundation | 无 |
| | `DualSenseReport.swift` | 149 | Foundation | 无（USB 0x02 / 蓝牙 0x31、CRC、输入解析都是纯函数） |
| | `ControllerSettings.swift` | 121 | Foundation（`UserDefaults`） | `SettingsStore` 改为依赖键值存储协议 |
| | `ControllerIdentity.swift` | 33 | Foundation | 身份字符串规则各平台补充（§6.2、§7.3） |
| | `SpeakerDSP.swift` | 230 | Foundation | 无（`RingCursor`、`AdaptiveMargin`、`DelayLine`、`SpeakerFeed`…） |
| | `Latency.swift` | 98 | Foundation（`UserDefaults`） | `SpeakerTuning.load` 改为依赖键值存储协议 |
| | `Localization.swift` | 29 | Foundation | 语言选择改为依赖键值存储协议 |
| | 小计 | **~1,250** | | 这些文件已有 6 组单元测试，可直接在 Windows / Linux / Android 上跑 |
| **逻辑与平台混在一起，抽出后复用** | `ControllerSession.swift` | 425 | AppKit、Combine、CoreAudio、GameController | `tick()` 里的扳机调强度、震动计算、对齐延迟、灯光计算、白灯电平是纯逻辑 → 抽成 `SessionEngine`（§5.2） |
| | `DualSenseHID.swift` | 266 | IOKit | 「控制权交出 / 默认值 / 脏标记 / 0.1 秒保活 / 序号」状态机是纯逻辑 → 抽成 `DualSenseOutputController`；IOKit 收发留在 macOS |
| | `HDHaptics.swift` | 268 | AudioToolbox、CoreAudio | `HapticWaveform` 和渲染回调的计算（游标、增益渐变、HD 载波）是纯逻辑 → 抽成 `ControllerAudioRenderer`；AUHAL 留在 macOS |
| | `ControllerRegistry.swift` | 135 | GameController | 会话对账（新增 / 移除 / USB↔蓝牙迁移 / D5 复制设置）是纯逻辑 → 抽成核心；「发现设备」变成协议 |
| | `AppModel.swift` | 283 | AppKit、Combine、CoreAudio、GameController | 主循环、采集启停规则、防抖保存可以抽一部分；其余是 macOS 外壳 |
| **只属于 macOS** | `App.swift`（SwiftUI）、`SystemAudioTap.swift`、`CoreAudioUtils.swift`、`ControllerFeatures.swift`、`HapticEngines.swift` | ~700 | SwiftUI / CoreAudio / GameController / CoreHaptics | 各平台重写对应部分 |

所以「尽量复用」实际能复用的是：**全部纯逻辑 + 抽出后的会话引擎 / HID 状态机 / 音频渲染器 / 注册表对账**，约占非界面代码（~3,000 行）的 60–65%。每个平台要新写的是：系统声音采集、设备发现、HID 收发、4 声道音频设备、其他手柄的震动、界面。

## 2. 技术路线选择

| 方案 | 复用现有代码 | Windows | Android | 风险 | 结论 |
|---|---|---|---|---|---|
| **A. Swift 核心 + 各平台原生外壳** | 高（核心原样复用，测试照跑） | Swift 官方支持 Windows；界面用 C# / WinUI 3 或 swift-winrt | Swift 6.3 官方 Android SDK + swift-java（JNI）；界面用 Kotlin / Compose | Swift 在 Android 上较新（2026-03 正式版）；需要打包 Swift 运行库 | **推荐** |
| B. 整体改写成跨平台框架（Flutter / Kotlin Multiplatform / Rust + 各平台） | 无（全部重写） | 好 | 好 | 工作量最大，macOS 版也要重写或维护两份 | 不推荐 |
| C. 只做 Windows，用 C# 全部重写 | 无 | 好 | 不覆盖 | 维护两份核心逻辑，算法改动要同步两边 | 不推荐 |
| D. 用 SDL3 当整个平台层 | 中 | SDL 能做手柄输入 / 震动，**不能做系统声音环回采集** | 同样不能做播放采集 | 核心需求（采集）不覆盖 | 只用它处理「其他手柄」（§6.5） |

方案 A 的依据：
- Swift 6.3 带来了**第一个官方 Android SDK**，可以把现有 Swift 包编译到 Android，并通过 swift-java / Swift Java JNI Core 让 Kotlin / Java 调用 Swift 代码；**SwiftUI 不在 Android 上** [已证实，[9to5Google](https://9to5google.com/2026/03/28/swift-a-coding-language-developed-by-apple-now-offers-official-android-support/)、[i-programmer](https://www.i-programmer.info/news/98-languages/18766-swift-63-adds-android-sdk.html)；最低 API 级别 28 只见于二手文章 [待核实]]。
- Windows 上没有 Swift 写的界面框架。The Browser Company 做了 [swift-winrt](https://speakinginswift.substack.com/p/swift-meet-winrt) / [swift-winui](https://github.com/thebrowsercompany/swift-winui)，但 swift-winui「目前只支持 x64」、「并非所有 API 都能生成」，最后更新在 2025 年 3 月；另有社区的纯 Swift 重写 [tristanlabelle/swift-winrt](https://github.com/tristanlabelle/swift-winrt) [已证实]。所以 Windows 界面**建议用 C#（WinUI 3 或 WPF）写薄外壳**，Swift 核心编译成 DLL、导出 C 接口；swift-winui 作为备选（全 Swift，但有架构和成熟度风险）。

## 3. 平台能力调研

### 3.1 能力矩阵

✓ = 有公开 API、可行；◐ = 可行但有限制 / 未实测；✗ = 不可行；? = 未知，需要实测。

| 功能 | macOS（现状） | Windows · USB | Windows · 蓝牙 | Android · USB | Android · 蓝牙 |
|---|---|---|---|---|---|
| 系统声音采集 | ✓ process tap | ✓ WASAPI 环回 | 同左 | ◐ AudioPlaybackCapture（只能采允许采集的 App，每次要用户同意） | 同左 |
| 音乐分析 / 按摩 / 整形 | ✓ | ✓ 核心复用 | ✓ | ✓ 核心复用 | ✓ |
| DualSense 兼容震动 | ✓ HID | ✓ HID `WriteFile`（0x02） | ✓ HID（0x31） | A 档 ✓ `VibratorManager`；B 档 ✓ `HidDevice` | 同左 |
| 灯条 / 白灯 | ✓ HID | ✓ HID | ✓ HID | A 档 ✓ `LightsManager`（RGB + 玩家指示灯）；B 档 ✓ HID | 同左 |
| 扳机阻尼 | ✓ HID | ✓ HID | ✓ HID | **只有 B 档**（Android 17+） | **只有 B 档** |
| L2/R2 调强度 | ✓ | ✓ HID 输入报告 | ✓ | ✓ `MotionEvent` 扳机轴 | ✓ |
| HD 震动 | ✓ 4 声道音频 | ✓ 4 声道音频 [社区资料] | ◐ 0x32 触觉报告：有 Windows 实现，速率待测 | ? AAudio 4 声道（C 档） | ? B 档 + 0x32，速率待测 |
| 手柄扬声器 | ✓ 4 声道音频 | ✓ 4 声道音频 | ? 0x36 Opus，速率待测 | ? C 档 | ? B 档 + 0x36 |
| 其他手柄（8BitDo 等）震动 | ✓ GameController | ✓ SDL3 或 Windows.Gaming.Input | ✓ 同左 | ✓ A 档 `VibratorManager` | ✓ |
| 后台运行 | ✓ | ✓ | ✓ | ◐ 前台服务（通知栏常驻） | ◐ 同左 |
| 屏蔽 PS 键打开系统界面 | ✓（macOS「游戏」） | 不需要（Windows 没有对应行为；Steam 大屏幕模式可能会被唤起 [推测]） | 同左 | 不需要 | 不需要 |

### 3.2 Windows

**系统声音采集。** 两个选择：
- **普通环回**（`AUDCLNT_STREAMFLAGS_LOOPBACK`，采默认输出设备的混音）：所有 Windows 10/11 都能用。本 App 把声音输出到**手柄**这个设备，不是默认设备，所以采不到自己，**不会回声** [推测，依据 WASAPI 环回只采指定端点]。
- **进程环回**（`AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` + `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`）：排除本进程，最低 Windows 10 build 20348 [已证实，[Microsoft 文档](https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ns-audioclientactivationparams-audioclient_process_loopback_params)；`ActivateAudioInterfaceAsync` 页面的版本号前后矛盾，见 [该页](https://learn.microsoft.com/en-us/windows/desktop/api/mmdeviceapi/nf-mmdeviceapi-activateaudiointerfaceasync)]。只有在用户把手柄设为默认输出设备时才需要它。官方示例：[Application Loopback API Capture Sample](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)。
- Windows 没有 macOS 那样的「系统录音」隐私授权弹窗 [待核实]，所以 macOS 那套「后台线程启动、等授权」的流程可以简化（但保留后台启动，WASAPI 激活本身也可能慢）。

**HD 震动 + 扬声器（USB）。**
- 社区资料一致描述：DualSense 在 Windows 上是 **4 声道音频设备**，前 2 声道 = 内置扬声器 / 耳机，后 2 声道 = 触觉。把系统音频设为单声道会把同样的声音送到 4 个声道（包括触觉）[社区资料，[Steam 讨论](https://steamcommunity.com/app/2420110/discussions/0/4292566446032401450)]；Wine 为了让游戏的 DualSense 触觉正常工作，专门修了这个 4 声道设备的混音格式 [[Wine MR 337](https://gitlab.winehq.org/wine/wine/-/merge_requests/337)]。这与 macOS 上的布局一致 → **`ControllerAudioRenderer` 可以原样复用**，只换 WASAPI 外壳。
- **不需要像 macOS 那样发 HID 报告关掉兼容震动开关吗？** 现有 macOS 代码需要把震动标志位 bit0/bit1 清零才进入 HD 模式。Windows 上游戏也是同样通过 HID 报告切换的（同一个固件），所以**同样需要** [推测]。
- 扬声器同样需要先发 HID 报告打开通路（路径 3），与 macOS 相同 [推测]。
- 低延迟：WASAPI 共享模式默认周期约 10ms；`IAudioClient3::InitializeSharedAudioStream` 可以用更小的周期 [待核实具体数值]；独占模式更低，但会独占手柄的音频设备，游戏就不能同时用它。建议共享模式 + `IAudioClient3`。`LatencyModel` 的公式不变，只是 `DeviceTiming` 换成 WASAPI 的周期和流延迟（`GetStreamLatency`）。

**HID（DualSense）。**
- 用 Win32 HID：`SetupDiGetClassDevs` / `CM_Get_Device_Interface_List` 枚举，`CreateFile` 打开，`ReadFile` 读输入报告，**`WriteFile` 发输出报告**。微软文档说 `HidD_SetOutputReport` 只适合「设置集合的当前状态」，有的设备用它会失去响应 [已证实，[HidD_SetOutputReport](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/hidsdi/nf-hidsdi-hidd_setoutputreport)]，我们每 10ms 发一次，应当用 `WriteFile`。也可以直接带上 hidapi（C 库，BSD 许可证）。
- 报告格式与 macOS 完全相同：USB 0x02，蓝牙 0x31 + CRC → **`DualSenseReport` 原样复用**。
- 冲突：Steam Input、DS4Windows、DualSenseX、HidHide 可能会独占或隐藏手柄，需要在界面上提示 [推测]。SDL 文档也提到，一旦启用 DualSense 的「扩展报告」就要重新上电才能关掉，并会破坏不用 SDL 的程序的 DirectInput 处理 [已证实，[SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE](https://wiki.libsdl.org/SDL3/SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE)]——我们发 0x31 也会让蓝牙手柄切到扩展报告，要在说明里写清楚。

**蓝牙下的 HD / 扬声器。** macOS 的问题是链路被锁在 ~15ms 节拍、系统独占 HID 通道（见 [bluetooth-audio-findings.md](research/bluetooth-audio-findings.md) §6.5）。Windows 上：
- [awalol/dualsense-bt-haptics](https://github.com/awalol/dualsense-bt-haptics) 在 **Windows** 上用 SAxense 的蓝牙触觉报告驱动 DualSense 的 HD 震动（作者估计延迟约 200ms，归因于虚拟声卡）[已证实，见 findings §3]。这说明 Windows 的蓝牙 HID 至少能以触觉所需的速率（0x32，约 94 包/秒）送出报告 [推测]。
- 一篇报道说「Windows 根本处理不了手柄高级功能所需的 4 声道音频带宽」[[clubic](https://www.clubic.com/actualite-611413-la-dualsense-retrouve-ses-haptiques-sur-pc-grace-a-un-raspberry-pi-pico-2w-a-10.html)]，这说的是 Windows 没有原生的蓝牙手柄音频，与 HID 报告的吞吐量是两回事。
- → **Windows 蓝牙 HD 很可能可行，蓝牙扬声器（0x36 + Opus，37 KB/s）待测。** 把 `docs/research/bt-send-rate-probe.swift` 的逻辑改写成 Windows 版测一次就知道（§9 第 3 条）。

**其他手柄。** 8BitDo（Switch Pro 模式）、Xbox、DualShock 4：用 **SDL3** 的游戏手柄 API 做震动（跨平台，C 库，Swift 可直接调用）。但要通过提示关掉 SDL 自己的 PS5 驱动（`SDL_HINT_JOYSTICK_HIDAPI_PS5`），避免它和我们同时打开 DualSense [推测]。Xbox 手柄也可以走 `Windows.Gaming.Input`；本次调研没有找到 DualSense 在 `Windows.Gaming.Input` 下的震动支持资料。

### 3.3 Android

**系统声音采集（`AudioPlaybackCapture`，Android 10+）。** [已证实，[Android 文档](https://developer.android.com/media/platform/av-capture)、[AudioPlaybackCaptureConfiguration](https://d.android.com/reference/android/media/AudioPlaybackCaptureConfiguration)]
- 只能采到用途为 `USAGE_MEDIA`、`USAGE_GAME`、`USAGE_UNKNOWN` 的音频；对方 App 的采集策略必须允许（target SDK ≥ Android 10 的 App 默认允许，更老的 App 必须显式同意）；工作资料和个人资料之间不能互采。
- 需要 `RECORD_AUDIO` 权限 + 用户同意 MediaProjection 弹窗；Android 14+ 必须在 `mediaProjection` 类型的前台服务里运行，**每次会话都要重新征得同意**，令牌不能复用 [已证实，[Media projection](https://developer.android.com/media/grow/media-projection)]。
- 影响：大部分音乐 App 和游戏能采到；**有些 App 会退出采集**（流媒体视频 App 常见），采不到时界面要说明「此 App 不允许被采集」[推测]。

**手柄输出，三档：**

- **A 档：系统 API（Android 12 / API 31+，所有手柄）。**
  - `InputDevice.getVibratorManager()`：官方示例假设游戏手柄有左右两个马达，左马达在前 [已证实，[Controller features](https://developer.android.com/develop/ui/views/touch-and-input/game-controllers/controller-features?hl=en)]。
  - `InputDevice.getLightsManager()`：`LIGHT_TYPE_PLAYER_ID`（一排玩家指示灯）、`hasRgbControl()`（RGB 灯）[已证实，[Light](https://developer.android.com/reference/android/hardware/lights/Light)]。需要 `VIBRATE`、`LIGHTS` 权限。
  - 对 DualSense，底层是 Linux 内核的 `hid-playstation` 驱动，它支持灯条、玩家灯、兼容震动、电池、陀螺仪、触控板，**不支持自适应扳机和高级触觉** [已证实，[XDA](https://www.xda-developers.com/android-ps5-controller-support-getting-better/)、内核提交记录]。
  - 结论：A 档覆盖「跟随音乐 / 按摩的兼容震动 + 灯条 + 玩家灯（白点电平）」，USB 和蓝牙都能用，**不需要特殊权限**。是 Android 版的基础档。
  - 注意：`VibratorManager` 的振动是一次性效果（`createOneShot(duration, amplitude)`），要做 100Hz 的连续强度更新，需要验证频繁调用的延迟和是否会卡顿 [待实测]；振幅是 1–255 的整数。
- **B 档：`HidManager` / `HidDevice`（Android 17 / API 37）。**
  - Android 17 把「App 直接访问原始 HID 数据流」放在**危险级权限 `ACCESS_HID`** 之后 [已证实，[Android 17 企业版新功能](https://developer.android.com/work/versions/android-17)]。`HidManager` 枚举设备需要该权限，通常由**系统选择器或权限对话框**授予对具体设备的访问；`HidDevice` 提供 `sendOutputReport`（异步回调）、`getFeatureReport` 等；打开失败可能是底层节点（例如 hidraw）无法访问（`IOException`）或用户拒绝（`SecurityException`）；**App 在后台或缓存状态时访问可能受限** [已证实，[HidManager](https://developer.android.com/reference/android/hardware/hid/HidManager)、[HidDevice](https://developer.android.com/reference/android/hardware/hid/HidDevice)]。
  - 意义：**DualSense 的全部 HID 功能（扳机阻尼、灯条、白灯、兼容震动）直接复用 `DualSenseReport` 和抽出来的 `DualSenseOutputController`**，USB 发 0x02，蓝牙发 0x31。
  - 蓝牙 HD（0x32）/ 扬声器（0x36）：Android 的蓝牙 HID 走用户态蓝牙栈 + uhid [待核实]，速率与 macOS / Linux 都可能不同 → 实测。
  - 版本号标注为「37.1 / 37.2」，具体对应哪个 Android 发行版需要再确认 [待核实]。
- **C 档：USB 音频（HD 震动 + 扬声器，USB 连接时）。**
  - Android 支持 USB 音频设备；AAudio 在超过 2 声道时使用**按声道序号的掩码**而不是位置掩码（AOSP 修复多声道 USB 播放的提交），请求的声道数超过设备支持时高位声道会被丢弃，打开后必须查询实际声道数 [已证实，[AOSP 提交](https://gitlab.e.foundation/e/os/android_frameworks_av/-/commit/16c66dd1e60d6b65b846f371c2ae4bf2b673545f)、[AAudio 文档](https://developer.android.com/ndk/reference/a_audio_8h)]。
  - 能否以 4 声道打开 DualSense 的 USB 音频、第 3/4 声道是否真能送到触觉：**未知**，必须实测。AAudio 是 C API，**Swift 可以直接调用**，渲染回调里跑现有的 `ControllerAudioRenderer`。
  - HD 模式需要发 HID 报告清掉兼容震动位 → 依赖 B 档（Android 17）；更老的 Android 只能用 `UsbManager.claimInterface(force=true)` 抢占 HID 接口，代价是系统失去这个手柄的输入（游戏里不能用）[推测]。

**其他。**
- 电量：`InputDevice.getBatteryState()`（Android 12+）[待核实]。
- L2/R2 调强度：`MotionEvent.AXIS_LTRIGGER / AXIS_RTRIGGER`，但只在 App 前台时收得到 [推测]；后台时需要 B 档的 HID 输入报告。
- 平板与手机没有区别，界面做自适应布局即可。

## 4. 目标架构

```
┌──────────────────────── ControllerCore（Swift 包，所有平台共用）────────────────────────┐
│ MusicAnalyzer · Shaping · MassagePatterns · SpeakerDSP · Latency · DualSenseReport       │
│ ControllerSettings · ControllerIdentity · Localization                                    │
│ SessionEngine（每 10ms：扳机调强度、震动、对齐、灯光、白灯）                               │
│ DualSenseOutputController（交出 / 默认值 / 脏标记 / 保活 / 序号 → 产出报告字节）           │
│ ControllerAudioRenderer（4 声道：扬声器 ch1/2 + HD ch3/4，游标 / 渐变 / 载波）             │
│ SessionReconciler（会话对账、USB↔蓝牙迁移、D5）· AppCore（主循环、采集启停规则、保存）     │
└───────────────────────────── 只依赖下面这些协议 ─────────────────────────────────────────┘
   AudioCaptureSource · DeviceDiscovery · HIDLink · ControllerAudioDevice · GenericRumble · KeyValueStore
        │                    │                 │                 │                  │
   macOS 实现：           Windows 实现：       Android 实现：
   SystemAudioTap         WASAPI 环回          AudioPlaybackCapture（Kotlin → JNI）
   IOKit HID              Win32 HID / hidapi   HidDevice（Kotlin）/ A 档系统 API
   AUHAL                  WASAPI 共享模式      AAudio（Swift 直接调用）
   GameController         SDL3                 VibratorManager / LightsManager
   UserDefaults           注册表 / JSON 文件     SharedPreferences（经 JNI）
   SwiftUI                C# WinUI 3 / WPF     Kotlin / Compose
```

### 4.1 SwiftPM 目标划分

```
Package.swift
  ControllerCore          （library，Foundation + 可选 Synchronization，所有平台）
  ControllerCoreTests     （现有 6 组测试移到这里，在 macOS / Windows / Linux CI 都跑）
  ControllerMac           （library：SystemAudioTap、IOKit HID、AUHAL、GameController 适配）
  ControllerMusicVisualizer（executable：现有 SwiftUI App，依赖 ControllerCore + ControllerMac）
  ControllerWin           （library，#if os(Windows)：WASAPI、Win32 HID、SDL3；导出 C 接口给 C# 外壳）
  ControllerAndroid       （library，#if os(Android)：AAudio、JNI 入口；Kotlin 外壳经 swift-java 调用）
```

每个平台目标用 `#if os(...)` 包住，并在 `Package.swift` 里用 `.when(platforms:)` 条件依赖，保证 macOS 构建不受影响。

## 5. 核心抽取设计（P0 的具体内容）

### 5.1 平台协议

```swift
/// 系统声音采集：回调在音频线程，左、右、帧数、采样率（与现有 SystemAudioTap.onAudio 相同）
public protocol AudioCaptureSource: AnyObject {
    var onAudio: ((UnsafePointer<Float>, UnsafePointer<Float>, Int, Float) -> Void)? { get set }
    func start() throws          // 可能阻塞（macOS 等授权），AppCore 在后台线程调用
    func stop()
    var timing: DeviceTiming? { get }   // 延迟模型用
}

/// 一台 DualSense 的 HID 收发（macOS IOKit / Windows Win32 / Android HidDevice）
public protocol HIDLink: AnyObject {
    var transport: HIDTransport { get }            // .usb / .bluetooth
    func send(_ report: [UInt8]) -> Bool            // 完整报告（含报告 ID）
    var onInputReport: ((UInt32, [UInt8]) -> Void)? { get set }   // 交给 DualSenseReport.parseInput
}

/// 手柄的 4 声道音频设备（HD + 扬声器）：平台只负责把设备的回调接到 renderer.render
public protocol ControllerAudioDevice: AnyObject {
    init(renderer: ControllerAudioRenderer, ioFrames: Int) throws
    var timing: DeviceTiming { get }
    func stop()
}

/// 其他手柄的双马达震动（现有 HapticOutput 改名）
public protocol GenericRumble: AnyObject { func set(left: Float, right: Float); func stop() }

/// 设备发现：返回「身份 + 能力 + 打开各通道的工厂」，由核心的 SessionReconciler 对账
public protocol DeviceDiscovery: AnyObject {
    func discover() -> [DiscoveredController]
    var onChange: (() -> Void)? { get set }
}

/// 设置、语言、可调参数的存储（UserDefaults / 注册表或 JSON / SharedPreferences）
public protocol KeyValueStore { func data(forKey: String) -> Data?; func set(_ data: Data?, forKey: String) }
```

`DiscoveredController` 携带 `ControllerIdentity`、能力（`hasLight` / `hasAdaptiveTriggers` / `hasHD` / `hasSpeaker` / `canVibrate`）和三个可选工厂（`makeHIDLink`、`makeAudioDevice`、`makeRumble`）。能力从此由**平台声明**，不再由会话从 `GCController` 推断。

### 5.2 `SessionEngine`：会话逻辑的纯函数化

现在 `ControllerSession.tick()` 一边算一边直接调用 `hid.setLight`、`audio.set`、`output.set`。改成：

```swift
public struct SessionInput {          // 每个 tick 由平台层填
    var music: MusicFrame
    var triggers: (Float, Float)       // HID 输入报告或系统轴值
    var dt: Float
    var now: Double
}
public struct SessionCommands {       // 每个 tick 由引擎产出，平台层照做
    var motors: (Float, Float)?        // 兼容震动（HID 或 GenericRumble）
    var hd: (left: Float, right: Float, freq: Float, useMusic: Bool)?
    var light: (Float, Float, Float)?
    var playerLEDs: UInt8?
    var triggerResistance: Float?
    var intensity: Float?              // L2/R2 改了强度 → 写回设置
    var level: (Float, Float)          // 界面电平条
}
public struct SessionEngine {
    public var settings: ControllerSettings
    public let capabilities: ControllerCapabilities
    public mutating func tick(_ input: SessionInput) -> SessionCommands
}
```

现有的 `VibrationShaper`、`LightShaper`、`PlayerLEDMeter`、`DelayLine`、按摩时间、HD 频率映射全部搬进引擎，**逻辑一行不改**。好处：引擎可以写单元测试（喂合成的 `MusicFrame`，检查输出），各平台共享同一份行为。

### 5.3 `DualSenseOutputController` 与 `ControllerAudioRenderer`

- 现在的 `DualSenseHID` 里，「三项交给游戏时发默认值再放手、扬声器关闭时发一次路径 0、0.1 秒保活、蓝牙序号」都是纯状态机，只有最后的 `IOHIDDeviceSetReport` 是平台调用。拆成：
  - 核心：`DualSenseOutputController`，`mutating func update(...) -> [UInt8]?`（需要发送时返回报告字节）；
  - 平台：`HIDLink.send`。
- 现在的 `audioRender`（`HDHaptics.swift`）是一个 C 回调，里面的游标、自适应余量、增益渐变、软限幅、HD 载波都是纯计算。拆成：
  - 核心：`ControllerAudioRenderer.render(channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, frames: Int)`；
  - 平台：AUHAL / WASAPI / AAudio 的回调里只调用它。
  - 实时线程的约束（不加锁、不分配内存）不变。

### 5.4 跨平台细节

- **锁**：`MusicAnalyzer` 用的 `OSAllocatedUnfairLock` 只在 Apple 平台有。标准库的 `Synchronization.Mutex` 跨平台，但在 Apple 上要求 macOS 15+（本项目最低 14.2）[已证实，[Swift 论坛](https://forums.swift.org/t/sychronization-mutex-t-in-standard-library-but-restricted-to-ios-18/74803)]。做法：一个小的 `LockedBox<T>`，`#if canImport(os)` 用 `OSAllocatedUnfairLock`，否则用 `Mutex`。
- **单写单读环形缓冲的计数器**：`HapticWaveform.written` / `SpeakerFeed.written` 目前依赖「arm64 对齐整数读写是原子的」，严格说是数据竞争。Windows x64 和 Android arm64 上实际也成立，但应改用 `Synchronization.Atomic<Int>`（非 Apple 平台）或 swift-atomics，顺便消除未定义行为。
- **`UserDefaults`**：Windows / Android 上的 Foundation 有实现，但行为和存储位置不统一 [待核实]，统一走 `KeyValueStore`。
- **定时器**：主循环 100Hz。macOS 用 `Timer`；Windows 用多媒体定时器或带高精度标志的可等待定时器（`CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`）；Android 在前台服务的线程里用 `Choreographer` 以外的定时器（例如 `ScheduledExecutorService`）或 Swift 线程 + `nanosleep`。抽象成 `AppCore` 接收「tick」调用，由平台驱动。
- **Combine / ObservableObject**：只留在 macOS 外壳。核心通过回调或快照（`struct SessionSnapshot`）把状态交给界面。

## 6. Windows 版设计

### 6.1 组成

- `ControllerCore` + `ControllerWin`（Swift，编译成 `ControllerVisualizerCore.dll`，用 `@_cdecl` 导出 C 接口）；
- 界面外壳：C# + WinUI 3（或 WPF，更轻、更稳），经 P/Invoke 调 DLL；托盘图标，关闭窗口时缩到托盘继续运行。
- C 接口示意：`cv_start()`、`cv_stop()`、`cv_list_controllers(buf)`、`cv_get_settings(id, json)`、`cv_set_settings(id, json)`、`cv_get_snapshot(json)`（电平、电量、引擎状态，界面每 50ms 拉一次）。用 JSON 传设置，C# 端只做显示 / 绑定，不复制任何业务逻辑。

### 6.2 设备与身份

- DualSense：HID 设备接口路径 + **ContainerId**。Windows 把同一物理设备的 HID 接口和音频端点归在同一个 ContainerId 下（`DEVPKEY_Device_ContainerId`；音频端点也有 `PKEY_Device_ContainerId`）[待核实具体属性名]——这正好对应 macOS 上「音频 UID 含 LocationID」的匹配，两个 DualSense 时也能精确找到各自的音频设备。
- 身份字符串：USB 用 ContainerId，蓝牙用蓝牙地址（HID 设备路径里含 MAC [待核实]）。`ControllerIdentity` 增加 `windowsContainer(_:)`，键前缀不同，不与 macOS 冲突（设置不跨平台同步，无需统一）。
- 插拔：`CM_Register_Notification` 或 `RegisterDeviceNotification` 监听 HID 接口和音频端点变化 → 调核心的对账。macOS 的那条教训（自己创建的聚合设备会触发设备变化通知，只有连接方式真的变了才重启）在 Windows 上对应「打开 WASAPI 流也可能触发端点通知」，同样只按身份 / 连接方式对账 [推测]。

### 6.3 音频

- 采集：WASAPI 共享模式环回（默认设备）；若手柄是默认输出设备，改用进程环回排除本进程。
- 手柄输出：WASAPI 共享模式，事件驱动，格式 4 声道 float32 48kHz（以 `GetMixFormat` 实际返回为准）；回调里调 `ControllerAudioRenderer.render`。
- 延迟：`IAudioClient3` 取最小共享周期；`DeviceTiming` 填周期 + `GetStreamLatency`。

### 6.4 HID 发送线程

- `WriteFile` 是阻塞的（重叠 I/O 可以异步），放到专用线程，核心的 `DualSenseOutputController` 产出报告后入队。蓝牙 HD 实验成功时，同一线程以 10.667ms 节奏发 0x32 / 0x36。

### 6.5 其他手柄

SDL3 游戏手柄子系统：枚举、震动（`SDL_RumbleGamepad`）、灯（`SDL_SetGamepadLED`，支持的手柄）。启动时设置提示关闭 SDL 的 PS5 HIDAPI 驱动，让 DualSense 只由我们打开。身份：SDL 的 GUID + 序号。

### 6.6 打包

需要带上 Swift 运行库 DLL（`swiftCore.dll`、Foundation 等）[待核实具体列表与体积]；建议 MSIX 或 zip 免安装版。CI：GitHub Actions `windows-latest` 安装 Swift 工具链（例如 `compnerd/gha-setup-swift` [待核实]），`swift build` + `swift test` 跑核心测试，再用 `dotnet build` 打包外壳。

## 7. Android 版设计

### 7.1 组成

- Kotlin App（Jetpack Compose 界面，手机 / 平板自适应），一个**前台服务**承载全部运行逻辑（类型 `mediaProjection`；B / C 档另加 `connectedDevice` [待核实]）。
- `ControllerCore` + `ControllerAndroid` 用 Swift Android SDK 编译成 `.so`，经 swift-java 生成的 JNI 绑定被 Kotlin 调用。
- 职责划分：
  - **Kotlin**：权限与 MediaProjection 流程、`AudioRecord`（播放采集）、`InputDevice` 的震动 / 灯 / 扳机轴、`HidManager` / `HidDevice`、设置存储、界面。
  - **Swift**：分析、会话引擎、报告构造、4 声道渲染（AAudio 直接在 Swift 里打开）。
- 数据流：
  - `AudioRecord` 读到的 float 立体声块 → JNI 直接传 `ByteBuffer`（不拷贝）→ `MusicAnalyzer.process` + `SpeakerFeed.write`（与 macOS 的采集回调完全相同）。
  - 主循环 tick 在 Swift 里跑，产出 `SessionCommands` → A 档时回调 Kotlin 调 `VibratorManager` / `LightsManager`；B 档时直接产出报告字节 → Kotlin `HidDevice.sendOutputReport`。

### 7.2 分档实现

| 档 | 条件 | 能做什么 | 主要代码 |
|---|---|---|---|
| A | Android 12+，任何系统识别的手柄 | 跟随音乐 / 按摩的兼容震动、灯条、玩家灯（白点电平）、L2/R2 调强度（前台时） | Kotlin：`VibratorManager` 两个马达；`LightsManager` 会话；`MotionEvent` 扳机轴 |
| B | Android 17+，DualSense，用户授予 `ACCESS_HID` | A 档全部 + 扳机阻尼 + 精确灯条 / 白灯 + 后台 L2/R2（HID 输入报告）；蓝牙 HD / 扬声器视实测 | 复用 `DualSenseReport`、`DualSenseOutputController`；Kotlin `HidDevice` |
| C | USB 连接，且实测 AAudio 能以 4 声道打开 DualSense | HD 震动 + 扬声器同步播放 | 复用 `ControllerAudioRenderer`；Swift 调 AAudio |

运行时按能力降级：探测到 B 档可用就用 B，否则 A；C 档独立探测。界面按能力隐藏设置项，与 macOS 的 D8 规则相同（能力由平台声明，§5.1）。

### 7.3 身份与设置

- A 档：`InputDevice.getDescriptor()`（跨重启稳定的设备描述符）作为身份。
- B 档：`HidDevice` 的序列号 / 蓝牙地址 [待核实可用字段]。
- 设置存 `SharedPreferences`，经 `KeyValueStore` 接入核心。

### 7.4 采集与延迟

- `AudioRecord` + `AudioPlaybackCaptureConfiguration`（`addMatchingUsage(USAGE_MEDIA / USAGE_GAME / USAGE_UNKNOWN)`），48kHz float 立体声。
- 延迟模型：播放采集本身的延迟未知 [待实测]，`LatencyModel` 需要加一项「采集延迟」，由实测填入。
- 界面提示：「只能采到允许录音的 App；如果某个 App 没有反应，它可能禁止了录音」。

## 8. 分阶段计划

| 阶段 | 内容 | 验收 | 依赖实物 |
|---|---|---|---|
| **P0 重构** | 拆 `ControllerCore` / `ControllerMac`；抽 `SessionEngine`、`DualSenseOutputController`、`ControllerAudioRenderer`、`SessionReconciler`；协议化；锁和原子计数改造；测试移到核心并补引擎测试；CI 增加 Linux 和 Windows 的核心构建 + 测试 | macOS 行为完全不变（用多手柄文档 §11、扬声器文档 §8 的清单回归）；核心在 Linux / Windows CI 上编译通过、测试全绿 | Mac + 手柄（回归） |
| **P1 Windows USB** | WASAPI 采集；Win32 HID（USB）；4 声道输出（HD + 扬声器）；C# 外壳；托盘 | 单个 USB DualSense：音乐三模式、按摩、HD、扳机、灯光、扬声器、L2/R2 都工作；两个 DualSense 时音频设备对应正确 | Windows PC + DualSense |
| **P2 Windows 蓝牙 / 其他手柄** | 蓝牙 0x31；测蓝牙 0x32 / 0x36 速率，可行就做蓝牙 HD（及扬声器，需要 libopus）；SDL3 接其他手柄 | 蓝牙 DualSense 基础功能；8BitDo 震动；蓝牙 HD 视实测 | 同上 + 8BitDo |
| **P3 Android A 档** | Kotlin 外壳 + 前台服务 + 播放采集；Swift 核心经 JNI；`VibratorManager` / `LightsManager` | Android 12+ 手机 / 平板上，DualSense（USB / 蓝牙）和 8BitDo 跟随音乐震动、灯条跟随 | Android 12+ 设备 + 手柄 |
| **P4 Android B / C 档** | `HidManager` 路径；AAudio 4 声道探测与 HD / 扬声器 | Android 17 设备上扳机阻尼工作；USB 4 声道若可行则 HD / 扬声器工作 | Android 17 设备 |

## 9. 需要实物验证的问题（按对设计的影响排序）

1. **Android：`VibratorManager` 能否以 100Hz 更新强度而不卡顿 / 不累积延迟**（决定 A 档能否「跟随音乐」）。写一个只含一个按钮的测试 App 即可。
2. **Android 17：`HidDevice.sendOutputReport` 能否发 DualSense 的 0x02 / 0x31，速率多少**（决定 B 档；蓝牙下顺便测 0x32 / 0x36 的速率，对照 macOS 的 ~5 KB/s）。
3. **Windows 蓝牙：`WriteFile` 发 0x31 / 0x32 / 0x36 的速率**（把 `docs/research/bt-send-rate-probe.swift` 移植成 Windows 版，几十行）。≥ 94 包/秒 × 398 字节 → 蓝牙扬声器可行。
4. **Windows USB：DualSense 音频端点的混音格式**（`GetMixFormat` 是不是 4 声道），以及第 3/4 声道在共享模式下能否驱动触觉（社区资料说能）。
5. **Android USB：AAudio 能否以 4 声道打开 DualSense**（打开后查询实际声道数）。
6. **Windows：HID 接口和音频端点的 ContainerId 是否一致**（决定两个 DualSense 时的精确对应）。
7. **Android 播放采集的延迟**和哪些常用 App 禁止采集。
8. **Swift 运行库体积**（Windows DLL、Android `.so`），看是否需要裁剪。

## 10. 风险

- **Swift on Android 很新**（官方 SDK 2026-03 正式发布），JNI 绑定工具还在演进；万一卡住，退路是把核心里需要的部分用 Kotlin 重写（纯逻辑约 1,250 行，有现成测试可以对照），代价可控。
- **Windows 界面用 C#** 引入第二种语言；但 C# 只做界面绑定，业务逻辑都在 Swift 核心里。
- **第三方工具冲突**（Steam Input、DS4Windows、DSX）可能抢手柄；需要检测并在界面里提示。
- **Android 后台限制**：不同厂商的省电策略可能杀掉前台服务 [推测]；需要引导用户把 App 加入电池优化白名单。
- **P0 重构的回归风险**：会话、HID、音频渲染都要动。缓解：先给 `SessionEngine` 写「新旧实现逐 tick 输出相同」的对照测试，再删除旧代码。

## 11. 资料来源

- Swift：[Swift 6.3 / Android SDK（9to5Google）](https://9to5google.com/2026/03/28/swift-a-coding-language-developed-by-apple-now-offers-official-android-support/)、[i-programmer](https://www.i-programmer.info/news/98-languages/18766-swift-63-adds-android-sdk.html)、[Swift, meet WinRT](https://speakinginswift.substack.com/p/swift-meet-winrt)、[swift-winui](https://github.com/thebrowsercompany/swift-winui)、[tristanlabelle/swift-winrt](https://github.com/tristanlabelle/swift-winrt)、[Synchronization.Mutex 的平台限制](https://forums.swift.org/t/sychronization-mutex-t-in-standard-library-but-restricted-to-ios-18/74803)。
- Windows：[进程环回参数](https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ns-audioclientactivationparams-audioclient_process_loopback_params)、[ActivateAudioInterfaceAsync](https://learn.microsoft.com/en-us/windows/desktop/api/mmdeviceapi/nf-mmdeviceapi-activateaudiointerfaceasync)、[Application Loopback 示例](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)、[HidD_SetOutputReport](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/hidsdi/nf-hidsdi-hidd_setoutputreport)、[Steam 讨论：DualSense 4 声道](https://steamcommunity.com/app/2420110/discussions/0/4292566446032401450)、[Wine MR 337](https://gitlab.winehq.org/wine/wine/-/merge_requests/337)、[SDL3 PS5 震动提示](https://wiki.libsdl.org/SDL3/SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE)、[clubic 报道](https://www.clubic.com/actualite-611413-la-dualsense-retrouve-ses-haptiques-sur-pc-grace-a-un-raspberry-pi-pico-2w-a-10.html)、[awalol/dualsense-bt-haptics](https://github.com/awalol/dualsense-bt-haptics)。
- Android：[播放采集](https://developer.android.com/media/platform/av-capture)、[AudioPlaybackCaptureConfiguration](https://d.android.com/reference/android/media/AudioPlaybackCaptureConfiguration)、[Media projection](https://developer.android.com/media/grow/media-projection)、[Controller features](https://developer.android.com/develop/ui/views/touch-and-input/game-controllers/controller-features?hl=en)、[Light](https://developer.android.com/reference/android/hardware/lights/Light)、[HidManager](https://developer.android.com/reference/android/hardware/hid/HidManager)、[HidDevice](https://developer.android.com/reference/android/hardware/hid/HidDevice)、[Android 17 企业版新功能（ACCESS_HID）](https://developer.android.com/work/versions/android-17)、[AAudio](https://developer.android.com/ndk/reference/a_audio_8h)、[AOSP 多声道 USB 修复](https://gitlab.e.foundation/e/os/android_frameworks_av/-/commit/16c66dd1e60d6b65b846f371c2ae4bf2b673545f)、[XDA：Android 上的 PS5 手柄支持](https://www.xda-developers.com/android-ps5-controller-support-getting-better/)。
