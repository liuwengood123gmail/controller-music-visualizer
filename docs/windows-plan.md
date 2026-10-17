# Windows 版开发计划（P4 界面 + P5 底层，一起做）

> 状态：**计划**，还没开始写代码。给「在一台 Windows 机器上开发」用：背景、要装什么、按什么顺序做、每一步怎么验收，都写在这里。
> 已确定：界面用 **Compose Multiplatform（Desktop / JVM）**，复用 Android 的 Compose 界面、Kotlin 引擎接口和假引擎；底层复用 Swift 核心（编译成 Windows DLL）；**引擎复制一份**：Windows 引擎从 Android 引擎复制会话逻辑后独立修改，两边分开微调，Android 代码不动；P4、P5 在同一个分支上连着做。
> 先读：[design-notes.md](design-notes.md)（整体结构）、[android.md](android.md)（Android 实测结论）、[cross-platform-design.md](cross-platform-design.md) §3.2 / §6（Windows 调研）。

## 0. 一页总结

```
                 ┌──────────────── 复用（不改或小改）────────────────┐
Compose 界面 ui  │ ControllerApp / Strings（Android 现有，改成 KMP 共享）│
引擎接口         │ engine-api（纯 Kotlin，原样）                        │
假引擎           │ engine-fake（纯 Kotlin，原样）                       │
Swift 核心       │ ControllerCore + ControllerCAPI（编译成 .dll，原样）  │
                 └─────────────────────────────────────────────────────┘
                 ┌──────────────── Windows 新写 ──────────────────────┐
desktop          │ Compose Desktop 窗口 + 托盘                             │
engine-windows   │ Windows 引擎（Kotlin）：主循环、会话、对账、设置等从     │
                 │   Android 引擎复制后改写，平台调用换成 Windows 的        │
native-win       │ cvwin.dll（C++）：JNI 绑定、WASAPI 环回采集、          │
                 │   WASAPI 4 声道输出（HD + 扬声器）、Win32 HID、XInput、│
                 │   设备插拔通知、高精度定时                             │
                 └─────────────────────────────────────────────────────┘
```

- **最快的路**：Android 版已经把「界面 ↔ 引擎接口 ↔ Kotlin 引擎 ↔ C 接口 ↔ Swift 核心」整条链路跑通了；Windows 只是把 Android 的平台层（UsbManager / AAudio / VibratorManager / MediaProjection）换成 Windows 的（Win32 HID / WASAPI / XInput），引擎的会话逻辑从 Android 复制过来改写，界面和 Swift 核心直接共用。
- **实时线程不进 JVM**：采集回调、4 声道渲染回调都在 C++ 线程里直接调 Swift（`cv_core_process` / `cv_renderer_render`），和 Android 的 `usb_audio.c` / AAudio 回调一样。JVM 只跑 10ms 主循环和界面。
- **预计**：新写约 2,500–3,500 行（C++ ~1,200，Kotlin ~1,000，Gradle / 脚本 / CI ~300，测试 ~300），其中约 700 行是从 Android 引擎复制后改写的。熟悉的人 1–2 周能出可用预览版（不含蓝牙 HD / 扬声器）。

## 1. 背景（给没参与前面工作的人）

### 1.1 项目在做什么

把正在播放的系统声音变成手柄的震动和灯光：DualSense（PS5 手柄）跟随音乐震动、灯条变色、白灯做电平表；USB 时还有 **HD 震动**（音圈马达直接播波形）和**手柄扬声器同步播放**；也有按摩模式。macOS 版和 Android 版已经能用。

### 1.2 现有代码（master）

| 位置 | 内容 | Windows 怎么用 |
|---|---|---|
| `Sources/ControllerCore/` | Swift 平台无关核心：音乐分析、会话引擎（每 10ms 算震动 / 灯光 / 扳机 / 对齐）、DualSense 报告构造与发送状态机、4 声道渲染器、设置 / 补丁 / 对账 | **原样**编译进 DLL |
| `Sources/ControllerCAPI/` | 核心的 C 接口（`@_cdecl`，复杂数据走 JSON），头文件 `android/engine/src/main/cpp/controller_core.h` | **原样**；Windows 的 JNI 层调用它 |
| `contract/fixtures/` | Swift / Kotlin 共用的契约样例（设置 JSON、补丁、对账） | Kotlin 测试照跑 |
| `android/engine-api/` | Kotlin 引擎接口 `ControllerEngine`（StateFlow 状态 / 电平、事件、补丁命令）、数据类 | **原样** |
| `android/engine-fake/` | 假引擎（5 种剧本） | **原样**，界面开发用 |
| `android/ui/` | Compose 界面（手柄下拉、音乐 / 按摩、各开关滑块、电平条、中英文、宽屏两栏） | 改成 KMP：共享部分进 `commonMain`，授权弹窗等 Android 专有部分进 `androidMain` |
| `android/engine/` | Android 真实引擎：`AndroidControllerEngine`（主循环、命令、状态）、`Session`（每个手柄的输出通道和每 tick 的执行）、`Discovery`、`DualSenseLink`（USB 直连 / Android 17 HID）、`SystemOutput`（系统震动）、`PlaybackCapture`、`cv_jni.c`、`usb_audio.c` | **不改**。其中平台无关的部分（主循环、会话、对账、设置）复制到 Windows 引擎里改写 |
| `Sources/ControllerMusicVisualizer/` | macOS 外壳 | 只作参考（行为规则的出处） |

### 1.3 Windows 平台事实（调研结论，见 cross-platform-design §3.2）

- **系统声音**：WASAPI 共享模式**环回**（默认输出设备的混音）。手柄如果被设成默认输出设备，要改用**进程环回**排除本进程（Windows 10 20348+）。没有 macOS 那样的录音授权弹窗。
- **DualSense USB**：HID（`WriteFile` 发 0x02 输出报告，`ReadFile` 读 0x01 输入报告）+ 一个 **4 声道音频输出端点**（第 1/2 声道扬声器，第 3/4 声道触觉），与 macOS 布局相同 → `ControllerAudioRenderer` 原样复用。HD 模式要先用 HID 报告关掉兼容震动开关（核心的 `DualSenseOutputController` 已经处理）；扬声器要先用 HID 报告打开通路（同上）。
- **DualSense 蓝牙**：HID 发 0x31（带 CRC，核心已支持）。已有 Windows 程序在蓝牙下实现了 HD（0x32）和扬声器（0x36，Opus），且 Windows 蓝牙输入报告约 670 个/秒，**没有 macOS 的 15ms 节拍限制** → 蓝牙 HD / 扬声器很可能可行，放在最后做（§4 W8）。
- **其他手柄**：Xbox / 8BitDo（X 模式）走 **XInput**（左右马达 0–65535、扳机、电量）。
- **冲突**：Steam Input、DS4Windows、DSX、HidHide 可能独占或隐藏 DualSense；检测到打不开时界面提示。
- **定时**：Windows 默认计时器精度约 15.6ms，100Hz 主循环必须先 `timeBeginPeriod(1)`（或用高精度可等待定时器）。

### 1.4 从 macOS / Android 带过来的规则（照做，别重新踩坑）

- HID 报告：状态不变也每 0.1 秒重发；交给游戏的项在交出那一刻发一次默认值再放手；停止时恢复默认（核心已实现，平台只负责发）。
- HD：兼容震动开关（flag0 bit0–1）清零才进 HD；停止时恢复。HD 运行时**不要**再用其他方式发兼容震动。
- 扬声器：通路路径 3（耳机静音、扬声器 ← 右声道），硬件音量 0x64、前置放大 2（+6dB）；软件音量按分贝曲线、渐变；停止前先淡出。
- **设备变化通知会被自己触发**：打开 / 关闭音频流本身就会产生端点变化通知。会话只在「身份或连接方式真的变了」时重启，否则会无限重启（macOS 实际踩过）。
- 采集只做一份，所有手柄共享；每个手柄各自的设置（D2），新手柄复制选中手柄的设置（D5），按能力隐藏设置项（D8）。
- 原生库加载：Android 上踩过「Swift .so 缺 SONAME，JNI 层记下构建机绝对路径」的坑；Windows 对应的坑是 **DLL 搜索路径**（见 §5.3）。

## 2. 架构

### 2.1 Gradle 模块（仍放在 `android/` 这个 Gradle 根目录下，不搬目录，CI 路径不变）

```
android/
  engine-api/      纯 Kotlin（原样）
  engine-fake/     纯 Kotlin（原样）
  engine/          Android 真实引擎（不改）
  ui/              改为 Kotlin Multiplatform：commonMain（界面）+ androidMain + desktopMain
  app/             Android 组装（不变）
  engine-windows/  新：Windows 真实引擎（纯 Kotlin / JVM，从 engine 复制改写，见 2.3）
  desktop/         新：Compose Desktop 应用（窗口、托盘、参数），组装 ui + engine-windows / engine-fake
native-win/        新（仓库根目录）：cvwin.dll 的 CMake C++ 工程
```

依赖方向：`ui → engine-api`；`engine`、`engine-windows`、`engine-fake` → `engine-api`；`desktop → ui, engine-windows, engine-fake`。两个真实引擎之间没有依赖。

### 2.2 原生层：两个 DLL

- **`ControllerCAPI.dll`**（Swift，`swift build -c release --product ControllerCAPI`）+ Swift 运行库 DLL（`swiftCore.dll`、`Foundation*.dll`、`_FoundationICU.dll`、`swift_Concurrency.dll`、`BlocksRuntime.dll`、`dispatch.dll` 等，以 `dumpbin /dependents` 为准）。
- **`cvwin.dll`**（C++，MSVC 或 clang-cl）：
  - **JNI 绑定**：把 `cv_jni.c` 里「核心 / 会话 / DualSense 报告 / 渲染器 / 字符串接口」这几段原样拿过来（不含 AAudio 段），Java 侧类名不同（`app.cmv.engine.windows.NativeCore`），用宏改函数名前缀即可。
  - **采集**：WASAPI 环回线程 → 交错立体声 float → `cv_core_process`。
  - **手柄音频**：WASAPI 共享模式、事件驱动的 4 声道输出 → 回调里 `cv_renderer_render`。
  - **HID**：SetupAPI / `CM_Get_Device_Interface_List` 枚举 Sony 054C:0CE6 / 0DF2，`CreateFile` 打开（重叠 I/O），`WriteFile` 发、读线程 `ReadFile` 收；取 `HidD_GetAttributes`、`HidP_GetCaps`（报告长度）、`DEVPKEY_Device_ContainerId`、总线类型（USB / 蓝牙）。
  - **XInput**：`XInputGetState` / `XInputSetState` / `XInputGetBatteryInformation`。
  - **插拔通知**：`CM_Register_Notification`（HID 接口 GUID）+ `IMMNotificationClient`（音频端点），回调里只发一个「有变化」信号给 Kotlin，Kotlin 重新扫描、对账。
  - **定时**：`timeBeginPeriod(1)` / `timeEndPeriod(1)`。

为什么平台层用 C++ 不用 Swift：WASAPI 是 COM 接口，C++ 写最顺；Swift 在 Windows 上调 COM 很别扭。为什么不用 JNA / Java FFM 直接调 C 接口：实时音频回调不能进 JVM，反正要有一个原生 DLL，JNI 层又能直接从 Android 搬过来。

### 2.3 `engine-windows`：从 Android 引擎复制

**为什么复制而不抽公共模块**：Android 引擎里有很多按实机调出来的细节（录屏授权保留时长、灯光节流、力度曲线、USB 等时传输），Windows 上的设备行为也会不同、要单独调。两个引擎分开，各自改、各自微调，互不影响，也不用在 Windows 机器上回归 Android。代价是共通规则要手动同步（见下面的清单）。

**复制清单**（`android/engine/src/main/kotlin/app/cmv/engine/android/` → `android/engine-windows/src/main/kotlin/app/cmv/engine/windows/`）：

| Android 文件 | 复制后怎么改 |
|---|---|
| `AndroidControllerEngine.kt`（465 行） | → `WindowsControllerEngine.kt`。保留：单线程执行器、10ms 主循环（约 33Hz 发电平和状态）、命令处理、对账（经 C 接口调 Swift 的 `SessionReconciler`）、设置记忆与 D5、状态快照。删掉：MediaProjection / 前台服务 / USB 权限广播 / Android 17 HID / 扳机轴转发。换成：WASAPI 采集的启停（不需要授权，`provideCaptureConsent` 空实现）、插拔通知轮询、XInput 槽位扫描 |
| `Session.kt`（345 行） | → 同名。保留：能力判断、引擎名文字、设置变化时的重启规则、启停顺序（先停音频再恢复 HID）、每 tick 调 `sessionTick` 再分发、对齐延迟、延迟分解。换成：`DualSenseLink` 用 Win32 HID 实现、手柄音频用 WASAPI、`SystemOutput` 换成 XInput 的 `GenericRumble`；删掉 USB 直连 / HID17 / 系统灯光那几条分支和「授权」提示 |
| `NativeCore.kt`（82 行） | → 同名，包名改为 `app.cmv.engine.windows`（JNI 函数名带包名）；去掉 AAudio / USB 音频那几个，加 Windows 原生层的函数（采集、WASAPI 输出、HID、XInput、通知计数） |
| `SettingsStore.kt`（26 行） | → 同名，`SharedPreferences` 换成 `%APPDATA%\ControllerMusicVisualizer\settings.json`（同样的 JSON 格式） |
| `Discovery.kt`（72 行） | 只参考身份规则，按 §W6 重写 |
| `DualSenseLink.kt`（126 行） | 只复制 `DualSenseLink` 接口和输入解析（`InputParser`），实现重写 |
| 其余（`SystemOutput`、`PlaybackCapture`、`ControllerAudio`、`EngineService`、`Hid17Link`） | 不复制，Windows 有自己的对应物 |

**两个引擎要保持一致的规则**（改一边时检查另一边；在两个文件顶部注释里各写一句「与 Android / Windows 引擎同步的规则见 docs/windows-plan.md §2.3」）：

- 会话重启条件：只有身份、连接方式或「来源 / 震动 / HD / 扬声器」开关变化才重启；音量、阻尼、灯光速度等实时生效。
- 停止顺序：先停手柄音频（扬声器淡出），再发恢复默认的 HID 报告。
- 能力 → 设置项显示（D8）、新手柄复制选中手柄的设置（D5）、设置保存的键和格式（`controllerSettings.v1`）。
- 状态快照的节奏（命令立即发、内部变化约 33Hz 合并发）和电平频率（约 30Hz）。

Swift 核心里的规则（每 tick 的计算、报告构造、对账、对齐延迟、渲染）两边本来就共用，不在这个清单里。

### 2.4 `ui` 改成 Kotlin Multiplatform

- `commonMain`：`ControllerApp` 的界面部分、`Strings.kt`、滑块 / 开关 / 电平条。
- `androidMain`：屏幕录制授权弹窗（`MediaProjectionManager`）、运行时权限（录音 / 通知 / HID）、`LanguageStore`（SharedPreferences）。
- `desktopMain`：没有采集授权（WASAPI 环回不需要），`CaptureStatus.NeedsConsent` 不会出现；`LanguageStore` 用 `java.util.prefs.Preferences`；`collectAsStateWithLifecycle` 换成 `collectAsState`（或用 JetBrains 的多平台 lifecycle 库）。
- 做法：把 Android 专有调用收进几个 `expect` 函数（`CaptureConsentFlow`、`PermissionEvents`、`rememberStartWithPermissions`、`LanguageStore`），两边 `actual`。Desktop 版窗口宽度 ≥ 720dp 时自动是两栏布局（现有逻辑）。

### 2.5 Desktop 应用（`desktop/`）

- `main()`：`application { Window(...) { ControllerApp(engine) } ; Tray(...) }`；关闭窗口 = 缩到托盘，引擎继续跑；托盘菜单：显示窗口 / 开始·停止 / 退出。
- 引擎选择：默认 Windows 真实引擎；`--fake-engine [scenario]` 或右上角 ⋮ 切假引擎（与 Android / macOS 一致）。
- 调试入口：命令行参数 `--autostart`、`--massage`、`--select <n>`（与 macOS 相同），日志写 `%LOCALAPPDATA%\ControllerMusicVisualizer\logs\`。
- 设置：`%APPDATA%\ControllerMusicVisualizer\settings.json`（键 `controllerSettings.v1`，格式与 macOS / Android 相同）。

## 3. 环境搭建（Windows 10 22H2 或 Windows 11，x64）

### 3.1 要装的东西

| 工具 | 用途 | 装法（PowerShell，管理员） |
|---|---|---|
| Git | 拉代码 | `winget install --id Git.Git` |
| Visual Studio 2022 Build Tools | MSVC、Windows SDK（WASAPI / HID / XInput 头文件和库）、CMake、Ninja；Swift 也要它 | `winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.CMake.Project --includeRecommended"` |
| Swift 6.3.x for Windows | 编译 Swift 核心 DLL | `winget install --id Swift.Toolchain`（装完重开终端；版本与 CI 的 Linux / Android 保持同一个小版本，目前 6.3.3） |
| JDK 21（Temurin） | Gradle、Compose Desktop、jpackage | `winget install --id EclipseAdoptium.Temurin.21.JDK` |
| Android SDK（可选） | 只有要在这台机器上编 Android 时才需要；W3 改 `ui` 为 KMP 后 Gradle 同步 Android 模块要它 | 装 Android Studio，或 cmdline-tools + `sdkmanager "platforms;android-36" "platforms;android-37.2"`；不装时用 `-PdesktopOnly` 只配置 desktop 相关模块（W3 里加这个开关） |
| IntelliJ IDEA Community（可选） | 写 Kotlin / Compose，有预览 | `winget install --id JetBrains.IntelliJIDEA.Community` |
| Claude Code（可选） | 在这台机器上让 Claude 按本文档开发 | 按官方文档装 Windows 版（原生安装或 `npm i -g @anthropic-ai/claude-code`，需要 Git for Windows） |
| 调试工具（可选） | 看 HID 设备、音频端点 | [USB Device Tree Viewer](https://www.uwe-sieber.de/usbtreeview_e.html)（看描述符 / ContainerId）、`mmsys.cpl`（声音设置里看手柄端点的声道配置）、`hidapitester`（手发报告） |

装完检查：

```powershell
git --version; swift --version; java -version
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
```

C++ 和 Swift 都要在「x64 Native Tools Command Prompt for VS 2022」（或先运行 `vcvars64.bat`）里构建。

### 3.2 硬件

- DualSense（USB-C 数据线，不是只充电的线）；电脑自带或外接蓝牙 5.x 适配器（测蓝牙）。
- 可选：Xbox 手柄或 8BitDo（X 模式）测 XInput；第二个 DualSense 测多手柄。
- 测之前**退出 Steam**（或在 Steam 里关掉 PlayStation 手柄支持），卸载 / 停用 DS4Windows、DSX、HidHide。

### 3.3 拉代码、确认现有部分能编

```powershell
git clone https://github.com/liuwengood123gmail/controller-music-visualizer.git
cd controller-music-visualizer
git checkout -b claude/p4-p5-windows

swift build                    # 核心 + C 接口（macOS 目标在 Windows 上自动跳过）
swift test                     # 145 个测试，应全部通过（W2 要确认的第一件事）
native-win\scripts\build-swift.ps1   # release DLL + Swift 运行库 → native-win\out\x64
cd android
.\gradlew.bat -PdesktopOnly :engine-api:test :engine-fake:test   # 纯 Kotlin 部分；-PdesktopOnly 时不需要 Android SDK
```

实测注意（Windows 11 + Swift 6.4.1）：
- `swift` 必须在 VS x64 环境里跑（缺 `link.exe` 会报 toolchain is invalid）；`build-swift.ps1` 自己导入 vcvars。
- 装完 Swift / JDK 后**新开终端**：旧终端里没有 `SDKROOT`（报 unable to load standard library）和 `JAVA_HOME`。
- 没开「开发者模式」时 SwiftPM 建不了 `.build\release` 符号链接（只是警告）；产物实际在 `.build\out\Products\Release-windows-x86_64\`。
- 6.4.1 编译时有一堆 `wchar_t ... broken by a context change` 警告，来自工具链自带的 WinSDK 模块，不是项目代码，可忽略。
- Release 版 `ControllerCAPI.dll` 导出全部 36 个 `cv_*`（与 `controller_core.h` 一致），不需要额外导出设置；连同运行库共 19 个 DLL、约 58MB（运行库目录自带 `VCRUNTIME140` / `MSVCP140`，一起拷了）。

## 4. 开发步骤

每一步都有「做什么 / 验收」，做完一步提交一次；P4 的验收在 W4，P5 的验收在 W7。

### W1 实物探测（半天，先做，结果会改变后面的范围）

写一个一次性的探测程序 `native-win/probe/probe.cpp`（命令行，几十到一二百行），打印：

1. 所有音频输出端点：名字、`GetMixFormat`（声道数、采样率、格式、`dwChannelMask`）、`PKEY_Device_ContainerId`。**预期**：DualSense 的端点是 4 声道 48kHz。
2. 所有 Sony HID 设备：路径、VID / PID、总线（USB / 蓝牙）、`HidP_GetCaps` 的输入 / 输出报告长度、`DEVPKEY_Device_ContainerId`。**预期**：USB 时 HID 和音频端点的 ContainerId 相同（两个 DualSense 时靠它对号）。
3. 往 DualSense（USB）发一份 0x02 报告（灯条变红、兼容震动 50%），确认 `WriteFile` 成功、手柄有反应；读 1 秒输入报告，打印每秒个数和 L2 / R2。
4. 以共享模式打开手柄端点、往第 3/4 声道写 2 秒 80Hz 正弦（先用第 3 条把兼容震动开关清零），确认手里有 HD 震动；往第 1/2 声道写 1kHz 正弦，确认扬声器出声（先发打开扬声器通路的报告）。
5. 蓝牙：发 0x31 报告看灯条；连续发 5 秒，记录每秒能发多少个（对照 macOS 只有 ~65 个/秒）。

把输出贴进本文档 §7「实测记录」。如果第 1 / 4 条不成立（例如共享模式下只给 2 声道），HD / 扬声器改用独占模式或推迟，先做 HID 部分。

### W2 Swift 核心在 Windows 上编译和测试（半天）

- `swift build` / `swift test` 在 Windows 上全绿；有问题的地方（`UserDefaults`、`NSLock`、`Date` 等 Foundation 行为差异）在核心里修，Linux / macOS / Android CI 保持绿。
- `swift build -c release --product ControllerCAPI` 出 `ControllerCAPI.dll`；`dumpbin /exports` 能看到全部 `cv_*`（36 个左右）。如果 `@_cdecl` 函数没有导出，加 `-Xlinker /EXPORT:...` 或在 `Package.swift` 里为 Windows 加导出设置（只对 `.windows` 平台）。
- 写 `native-win/scripts/build-swift.ps1`：编译并把 `ControllerCAPI.dll` 和它依赖的 Swift 运行库 DLL（按 `dumpbin /dependents` 递归，类似 `android/scripts/build-swift-android.sh`）拷到 `native-win/out/x64/`。
- CI：`.github/workflows/build.yml` 加 `windows` 任务（`windows-latest`，安装 Swift，`swift build` + `swift test`）。

**验收**：Windows 上 145 个 Swift 测试通过；`out/x64/` 里有完整的 DLL 集合；CI 的 windows 任务绿。

### W3 界面改成多平台（半天）

1. `ui` 改成 KMP（`kotlin("multiplatform")` + Compose Multiplatform 插件 + `com.android.library`），按 §2.4 拆 `commonMain / androidMain / desktopMain`。界面代码本身不动，只把三四个 Android 专有的函数挪进 `androidMain`。Compose Multiplatform 版本选与 Kotlin 2.3.21 兼容的那一版（看 JetBrains 的兼容表）；AGP 保持 8.13.2。
2. `settings.gradle.kts` 加开关：`-PdesktopOnly` 时不 include `engine`、`app`，且 `ui` 不配置 Android 目标（没装 Android SDK 也能编 desktop）。
3. Android 确认：CI 的模拟器测试绿，CI 出的 APK 装上点一遍界面（这一步只动了界面的文件位置，不需要细测）。

**验收**：`ui` 的 `desktopMain` 能编译；Android 界面不变。Android 引擎不动。

### W4 Desktop 应用 + 假引擎（P4 验收，1 天）

- `desktop` 模块：Compose Desktop 窗口（宽 440dp 起，可拉宽到两栏）、托盘、语言切换、`--fake-engine`、⋮ 菜单切剧本。
- `./gradlew :desktop:run -PdesktopOnly` 直接跑；`:desktop:createDistributable` 出免安装目录（含精简 JRE）。
- 假引擎的 5 个剧本逐个点一遍：没有手柄、一个 USB DualSense（含「授权」卡片——Windows 上这张卡片换成冲突提示，见 W6）、多手柄、采集失败、运行中拔出。

**验收（P4）**：假引擎下界面完整可用；关窗口缩到托盘、托盘能开始 / 停止 / 退出；免安装包在一台干净的 Windows 上能直接运行。

### W5 cvwin.dll 骨架 + JNI + 采集（1 天）

- `native-win/` CMake 工程：`cvwin.dll` 链接 `ControllerCAPI.lib`（导入库）、`ole32`、`avrt`（MMCSS）、`hid`、`setupapi`、`cfgmgr32`、`xinput`、`winmm`。
- JNI：按 §2.2 从 `cv_jni.c` 搬核心几段；Kotlin 侧 `engine-windows/.../NativeCore.kt`（从 Android 复制，见 §2.3）。
- DLL 加载：启动时 `System.load` 绝对路径加载 `cvwin.dll`；`cvwin.dll` 的 `DllMain` 或第一个调用里 `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) + AddDllDirectory(<自己所在目录>)`，保证 Swift 运行库从同一目录加载，而不是从 PATH 里随便找到的另一个 Swift 版本（见 §5.3）。
- 采集：WASAPI 环回线程（`AUDCLNT_STREAMFLAGS_LOOPBACK`，48kHz float 立体声；设备格式不同就用 `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`），MMCSS「Pro Audio」优先级，每块直接 `cv_core_process`；默认设备切换时重开（`IMMNotificationClient::OnDefaultDeviceChanged`）。
- `timeBeginPeriod(1)`，Kotlin 主循环 10ms。
- 先用一个临时的 Windows 引擎：只有采集 + 一个「把电平发给界面」的假会话，确认整条链路（采集 → Swift 分析 → JNI → Kotlin → Compose 电平条）通了。
- JNI 冒烟测试：`engine-windows` 模块的 JVM 测试里把每个 native 函数调一遍（对应 Android 的 `NativeCoreTest`）。

**验收**：放音乐时界面电平条跟着跳；JNI 测试通过。

### W6 Windows 引擎：DualSense USB（2–3 天，主体）

0. 按 §2.3 的清单把 Android 引擎复制到 `engine-windows`，先删掉 Android 专有分支、编译通过（平台调用先留空实现）。
1. **发现**：Kotlin 侧 `Discovery.discover()` 调 `cvwin` 枚举 HID + 音频端点 + XInput 槽位，生成 `Found`：
   - DualSense：身份 = USB 时 ContainerId（`ds:win:<containerId>`），蓝牙时 HID 路径里的蓝牙地址（`ds:bt:<mac>`）；`link` = USB / 蓝牙；音频端点按 ContainerId 对上（只有一个手柄时退回按名字）。
   - XInput 手柄：身份 = `gp:xinput:<slot>`（XInput 拿不到序列号，按槽位）。
2. **HID**：`DualSenseLink` 的 Windows 实现：发送队列 + 专用写线程（`WriteFile` 会阻塞，不能在主循环里等），读线程解析输入报告（`cv_ds_parse_input`）给 L2/R2 / 电量。打开失败（被 Steam / HidHide 占用）时，卡片显示「这个手柄被别的程序占用（Steam / DS4Windows 等），请先退出」（复用 `ControllerInfo.access` 的提示位置，或在状态里给 `error`）。
3. **4 声道输出**：`ControllerAudioOut` 的 Windows 实现：WASAPI 共享模式、事件驱动、`IAudioClient3::InitializeSharedAudioStream` 取最小周期（不支持时退回 `Initialize` + 10ms），回调里 `cv_renderer_render`。HD / 扬声器的开关、淡出、对齐延迟沿用复制过来的 `Session` 逻辑。
4. **插拔**：`CM_Register_Notification` + `IMMNotificationClient` → Kotlin 重新扫描 → 对账；只在身份 / 连接方式变化时重启会话（§1.4）。
5. **托盘 / 后台**：窗口关了照样跑；退出时所有手柄恢复默认（停止报告、扬声器关、HD 关）。

**验收**：一个 USB DualSense 全功能——跟随音乐 / 按摩震动、HD 震动、扳机阻尼、R2/L2 调强度、灯条、白灯、手柄扬声器同步播放、延迟显示；拔插、切到后台、关窗口到托盘都正常；退出后手柄恢复默认、Steam 等程序再用手柄正常。

### W7 蓝牙 DualSense、其他手柄、多手柄、打包（P5 验收，1–2 天）

- **蓝牙 DualSense**：HID 0x31（核心已支持 CRC 和序号）；注意蓝牙下手柄最初只发简化的 0x01 输入报告，要先读一次特征报告 0x05（校准数据）或发一份 0x31 输出报告，它才切到完整的 0x31 输入报告；能力：震动、扳机阻尼、灯条、白灯，**没有** HD / 扬声器（W8 再做）。
- **XInput 手柄**：`GenericRumble` 的 Windows 实现（左右马达）、扳机轴调强度、电量；没有灯光。
- **多手柄**：两个 DualSense（一个 USB、一个蓝牙；或两个 USB），各自设置、各自输出，音频端点对号正确。
- **打包**：`:desktop:packageMsi`（或 `createDistributable` + zip）；把 `cvwin.dll`、`ControllerCAPI.dll`、Swift 运行库 DLL 放进 `appResourcesRootDir`；CI 的 windows 任务出包、上传 artifact，并像 Android 一样更新一个 `windows-preview` 预发布版。
- 文档：新增 `docs/windows.md`（安装、输出方式、实测结论、调试），README 的平台表加 Windows 一列。

**验收（P5）**：USB / 蓝牙 DualSense 和 XInput 手柄都能用；两个 DualSense 时音频端点对号正确；安装包在干净的 Windows 10 / 11 上能装能跑；CI 出包。

### W8（可选）蓝牙 HD 震动 + 扬声器

- 先用 W1 第 5 条的发送速率结果判断：蓝牙 HD 需要约 94 包/秒 × 0x32 报告；扬声器需要 0x36 报告里带 Opus 帧。
- 协议细节参考 [SAxense](https://github.com/egormanga/SAxense)（0x32 触觉）和 DualSenseClient / dualsense-studio 的公开描述。**DualSenseClient 是 GPL-3.0，本仓库没有许可证：只能参考协议，不能复制代码。** Opus 编码用 libopus（BSD）。
- 在核心里加「蓝牙触觉 / 音频报告」的构造（Swift，带单元测试），Windows 只负责按 10.667ms 节奏发送。

## 5. 关键技术细节

### 5.1 JNI 与线程

- Kotlin 主循环（单线程执行器，与 Android 相同）调 `sessionTick` 等；采集线程、渲染线程、HID 读写线程都在 C++ 里，不回调 JVM。
- 原生 → Kotlin 只有两个方向的信息：插拔「有变化」信号（C++ 线程里 `AttachCurrentThread` 调一个 Kotlin 回调，或 Kotlin 每 500ms 轮询一个计数器——更简单，推荐）；HID 输入报告解析结果（C++ 存最新值，Kotlin 每 tick 读）。

### 5.2 音频格式

- 采集：环回拿到的是设备混音格式（常见 48kHz float 立体声；也可能 44.1kHz 或多声道），只取前两声道，采样率按实际值传给 `cv_core_process`（核心支持任意采样率）。
- 手柄输出：以 `GetMixFormat` 为准；`cv_renderer_render` 写交错 float，声道数 > 4 时多余声道写 0（核心已处理）；格式不是 float 时在 C++ 里转换。
- MMCSS：渲染和采集线程都 `AvSetMmThreadCharacteristicsW(L"Pro Audio")`。

### 5.3 DLL 加载顺序（Windows 版的「SONAME 坑」）

- Windows 找依赖 DLL 的顺序会先看 exe 所在目录和 PATH；开发机上 PATH 里有 Swift 工具链的运行库，打包后的机器上没有 → 开发时能跑、装到别人机器上不能跑，或者反过来加载到不同版本。
- 做法：所有 DLL 放在同一个目录；Kotlin 用绝对路径 `System.load(<dir>\cvwin.dll)`；`cvwin.dll` 用**延迟加载**链接 `ControllerCAPI.dll`（`/DELAYLOAD`），在第一次调用前 `AddDllDirectory(<dir>)` + `SetDefaultDllDirectories`。
- CI 里在一个没装 Swift 的干净 runner 步骤上跑一次 JNI 冒烟测试（把 PATH 里的 Swift 去掉），防止「开发机能跑」的假象。

### 5.4 体积

JRE（jlink 精简）约 50–70MB + Swift 运行库约 60MB（其中 ICU 约 30–40MB）+ 应用本身 ~10MB。先不裁剪；以后可以让核心只依赖 `FoundationEssentials` 去掉 ICU（Android 也受益）。

## 6. 复用与工作量

| 部分 | 来源 | 复用方式 | 新写 / 改动（约） |
|---|---|---|---|
| Swift 核心 + C 接口 | `Sources/` | 原样（可能有少量 Windows 兼容修正） | 0–100 |
| 契约样例 / Kotlin 接口 / 假引擎 | `contract/`、`engine-api`、`engine-fake` | 原样 | 0 |
| 界面 | `android/ui` | 共享：改 KMP，Android 专有部分收进 expect/actual | 150–250（大多是搬动） |
| 引擎逻辑 | `android/engine` | 复制到 `engine-windows` 后改写（Android 不动） | 约 700 复制 + 300–500 改写 |
| Desktop 应用 | 新 | 窗口、托盘、参数、Windows 平台适配 | 500–700 Kotlin |
| cvwin.dll | 新（JNI 段搬 `cv_jni.c`） | WASAPI ×2、HID、XInput、通知、定时 | 1,000–1,400 C++ |
| 探测程序 | 新 | 一次性 | 150 |
| 构建脚本 / CI / 打包 | 新 | 仿照 Android 的脚本和 CI | 200–300 |
| 测试 | 新 | JNI 冒烟、Windows 引擎单测（平台调用用假实现） | 200–300 |
| 文档 | 新 | `docs/windows.md`、README | — |

## 7. 实测记录（W1 起在这里补）

实测环境：Windows 11 Pro 26200，DualSense（PID 0x0CE6）USB 连接，探测程序 `native-win/probe/`（`probe list|hid|hd|speaker [振幅]`）。

| 项目 | 结果 |
|---|---|
| DualSense 音频端点混音格式 | 共享模式 **4 声道、48kHz、32 位 float，`dwChannelMask=0x33`**（FL/FR/BL/BR），名字 `Speakers (DualSense Wireless Controller)`，与 macOS 布局相同 |
| HID 与音频端点 ContainerId 是否一致 | **一致**（HID 用 `CM_Get_DevNode_PropertyW(DEVPKEY_Device_ContainerId)`，端点用属性库里的同一个键）。HID 接口是 `mi_03`，报告长度 in=64 / out=48 |
| USB 共享模式第 3/4 声道能否驱动 HD | **能**。先发 flag0 bit0–1 和字节 38 清零的 0x02 报告，再往第 3/4 声道写 80Hz 正弦，手感正常 |
| HID 0x02 输出 | `WriteFile`（重叠 I/O）28/28 成功；灯条、兼容震动、恢复默认都正常 |
| USB 输入报告速率 | **250 个/秒**；L2/R2（字节 5/6）读数正常 |
| 扬声器 | **能**（路径 3、音量 0x64、前置放大 2，第 1/2 声道 1kHz）。**注意**：这台机器上 DualSense 端点的 Windows 音量是 0%（-100dB），扬声器几乎无声；音量调到 100% 后正常。HD 在 0% 时照样正常 → 端点音量只作用于扬声器声道，不影响触觉声道。**已定**：引擎**不**自动改端点音量；开扬声器时如果端点音量很低或静音，界面提示用户去声音设置里调（W6 实现） |
| 蓝牙 0x31 发送速率 | 待测（需要蓝牙连接） |
| 环回采集延迟（周期 / 缓冲） | 待测（W5） |
| 冲突软件 | 机器上装了 Steam（有 Steam Streaming 虚拟声卡）；Steam 未运行时 HID 读写正常 |

## 8. 在 Windows 机器上让 Claude 做的话

在仓库目录启动 Claude Code，第一句给它：

> 按 docs/windows-plan.md 开发 Windows 版，从 W1 开始，每完成一步提交并告诉我验收结果；分支 claude/p4-p5-windows，做完开 PR。

每一步需要你动手的地方（插拔手柄、听扬声器、感受震动）它会停下来问。W1 的探测结果填回 §7 后再继续。
