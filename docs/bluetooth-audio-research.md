# 蓝牙下的手柄扬声器（和 HD 震动）· 调研任务

> 状态：**调研**，不是实现任务。写给云端 agent。
> 你拿不到手柄也不能在 Mac 上运行程序：请**尽力查资料、读源码、写可在本机运行的验证程序**，把需要实物验证的步骤写清楚，交给仓库作者在本机跑。
> 手柄扬声器是本项目的重要功能。USB 下已经实现（见 [controller-speaker-design.md](controller-speaker-design.md)），本任务的目标是**找到在 macOS 上通过蓝牙让 DualSense 扬声器出声的办法**；顺带解决蓝牙下的 HD 震动（同一个通道）。

## 1. 结论先行：我们卡在哪里

macOS（本机 macOS 27.0.1，蓝牙芯片 Apple N1）通过 `IOHIDDeviceSetReport` 向蓝牙 DualSense 发输出报告，**吞吐量被限制在约 5 KB/s（≈40 kbps），与报告大小无关**；PS5 / Linux 的蓝牙扬声器需要约 **37 KB/s**（398 字节 × 每秒 94 包）。差约 7 倍。

**我们的判断（待你证实或推翻）**：每约 14ms 只能送出约 70 字节（一个分段），大报告被切成多段排队 → 很像蓝牙链路处于 **sniff（嗅探 / 省电）模式**，或 ACL 包类型 / L2CAP 通道参数受限，或 `SetReport` 走的是需要握手的 **控制通道（HID control, PSM 0x11）** 而不是 **中断通道（PSM 0x13）**。只要找到让吞吐量提高到 ≥ 40 KB/s 的办法，后面的编码和打包都有现成参考。

## 2. 本机实测数据（2026-10，DualSense 0x054C:0x0CE6，蓝牙）

### 2.1 不同大小输出报告的发送速率（同步 `IOHIDDeviceSetReport`，空报告，各 2 秒）

| 报告 | 大小（含 ID） | 每秒包数 | 吞吐量 |
|---|---|---|---|
| 0x31 | 78 | 69.5 | 5.3 KB/s |
| 0x32 | 142 | 35.5 | 4.9 KB/s |
| 0x33 | 206 | 24.0 | 4.8 KB/s |
| 0x34 | 270 | 17.5 | 4.6 KB/s |
| 0x35 | 334 | 14.5 | 4.7 KB/s |
| 0x36 | 398 | 13.5 | 5.2 KB/s |
| 0x37 | 462 | 12.0 | 5.4 KB/s |
| 0x38 | 526 | 10.5 | 5.4 KB/s |
| 0x39 | 547 | 9.5 | 5.1 KB/s |

规律：每秒包数 ≈ 69.5 ÷ ⌈大小 / 78⌉，即**每 ~14.4ms 一个 ~78 字节的分段**。

### 2.2 同步 vs 异步

| 方式 | 0x31（78B） | 0x36（398B） |
|---|---|---|
| 同步 `IOHIDDeviceSetReport` | 68 包/秒，单次最长 47ms | 15 包/秒，单次最长 120ms |
| 异步 `IOHIDDeviceSetReportWithCallback`（按 10.667ms 节奏提交，最多 16 个在途） | 61 包/秒 | 20 包/秒（有积压） |

异步几乎没有改善 → 瓶颈在系统 / 链路层，不在调用方式。

### 2.3 其他已知事实

- 蓝牙报告描述符（320 字节）：[research/dualsense-bt-report-descriptor.txt](research/dualsense-bt-report-descriptor.txt)。输出报告 0x31–0x39，大小 78、142、206、270、334、398、462、526、547；输入报告 0x01（10B）、0x31（78B）；`MaxOutputReportSize` 547，`MaxFeatureReportSize` 547。
- 测速程序源码：[research/bt-send-rate-probe.swift](research/bt-send-rate-probe.swift)（`swiftc -swift-version 5 -O bt-send-rate-probe.swift -o probe && ./probe`）。
- 之前的蓝牙 HD 震动实验（SAxense 格式的 0x32 报告，3kHz 8 位波形）：报告全部发送成功但手柄不震，当时只达到所需速率的约 1/3——很可能同一个原因。
- 蓝牙下 0x31 报告（震动强度、扳机、灯条）在本项目里工作正常（每 0.1 秒一次足够）。
- macOS 自己的 `gamecontrollerd` 也会给手柄发报告；Apple 的 CoreHaptics（`GCController.haptics`）在蓝牙下能让 DualSense 震动——**不知道它发的是什么报告、什么速率**，这是重要线索（§4 方向 A）。

## 3. 协议参考（Linux 已经做通）

两个 Linux 项目在蓝牙下实现了扬声器（以及基于音频的 HD 震动）：

- [GeorgLegato/LinuxAudio4Dualsense5](https://github.com/GeorgLegato/LinuxAudio4Dualsense5)（PipeWire sink）
- [mdrv/mdrv-ds-linux](https://github.com/mdrv/mdrv-ds-linux)（自己打开 L2CAP HID 通道的代理，`src/audio.rs`、`src/sink.rs`）
- 早期研究：[egormanga/SAxense](https://github.com/egormanga/SAxense)（0x32 震动）、[awalol/dualsense-bt-haptics](https://github.com/awalol/dualsense-bt-haptics)（Windows）

要点（来自上述 README，细节请读源码核实）：

| 项目 | 内容 |
|---|---|
| 报告 | 输出报告 **0x36**，398 字节，含子包：配置 0x11、状态 0x10、**震动 0x12**（64 × int8 @ 6kHz）、**扬声器 0x13**（耳机孔为 0x16） |
| 编码 | **Opus**，48kHz 立体声，**CBR 160 kbps**，每帧 200 字节 |
| 节奏 | 每 **10.667ms**（512 / 48000）一包：512 个输入采样重采样到 480 再编码；发 10ms 会累积偏差 |
| 校验 | CRC-32，种子 0xA2，覆盖前 394 字节 |
| 打开扬声器 | 先发 0x31：`audio_control = 0x30`（路径 3 = 扬声器），前置放大 2 |
| 链路 | Linux 项目是**直接写 L2CAP 中断通道**（mdrv 自己打开 HID 通道，需要 `bluetoothd --noplugin=input`），不经过 HID SET_REPORT 握手 |

macOS 上我们已有的相关代码：`DualSenseReport.swift`（0x31 报告与 CRC）、`DualSenseHID.swift`（HID 管理器、发送）、`HDHaptics.swift` / `SpeakerDSP.swift`（USB 下的扬声器 + HD 震动音频链路，可复用作数据源）。

## 4. 请调研的方向（按我们认为的优先级）

对每个方向，请给出：**可行性判断、依据（链接 / 源码位置 / 文档原文）、需要的权限或代价、可在本机运行的验证程序（若需要）**。

### 方向 A：Apple 自己怎么跟 DualSense 说话（最优先）

PS 是大厂，Apple 从 macOS 11 起官方支持 DualSense（GameController 框架里有 `GCDualSenseGamepad`、`GCDualSenseAdaptiveTrigger`），CoreHaptics 在蓝牙下也能驱动它。

1. 查 Apple 文档、WWDC（2020「Advancements in Game Controllers」及之后每年的 game controller / CoreHaptics 相关 session）、各版本 macOS / iOS 的发布说明：**是否有任何公开 API 能把音频送到手柄扬声器**（例如 `GCDeviceHaptics` 之外的音频相关属性、`AVAudioSession` / AVAudioEngine 的手柄路由、CoreHaptics 的 `CHHapticAudioResource` / `audioCustom` 事件在手柄引擎上是否会从手柄发声、`GCController` 的 audio / speaker 相关新属性）。
2. CoreHaptics 在蓝牙 DualSense 上是**真 HD（0x32/0x36 音频通道）还是兼容震动（0x31 马达字节）**？如果 Apple 自己能以 ~94Hz 发 0x36，说明系统内部有更快的通道，值得找到它的入口。
3. 设计一个本机实验，让仓库作者用 **PacketLogger**（Xcode「Additional Tools」里的蓝牙抓包工具）抓取：(a) 我们的测速程序发送时、(b) `gamecontrollerd` 用 CoreHaptics 播放一段连续震动时，链路上的 **L2CAP 通道（PSM 0x11 / 0x13）、ACL 包类型、包间隔、是否处于 sniff 模式**。写清楚操作步骤和要看哪些字段。

### 方向 B：为什么只有 ~5 KB/s，能不能提速

1. **SET_REPORT 走哪个通道**：读 Apple 开源代码（[apple-oss-distributions](https://github.com/apple-oss-distributions) 下的 IOHIDFamily；IOBluetoothFamily 若有开源版本也请查）里 `setReport` 在蓝牙 HID 设备上的实现：输出报告是走控制通道（带握手）还是中断通道（DATA）？有没有属性 / 选项能改成中断通道？（例如设备属性、`IOHIDDeviceSetProperty` 可设的键、`kIOHIDReportTypeOutput` 与 `IOHIDDeviceSetValue` 元素级写入的区别）。
2. **sniff 模式 / 链路策略**：macOS 是否给 HID 设备设置了 sniff 模式？有没有公开或半公开 API 让链路退出 sniff 或调整 sniff 间隔（`IOBluetoothDevice` 的方法、`IOBluetoothHostController`、HCI 命令接口、`blued` / `bluetoothd` 的配置或 defaults 键、开发者用的 Bluetooth Explorer 能否手动切换以做验证）。
3. **ACL 包类型 / L2CAP MTU**：每 ~14ms 只出 ~78 字节，是否因为只允许单时隙包（DM1/DH1）或 MTU 很小？能否协商更大的包。
4. 请把 2.1 的数据和你的解释对上：如果是 sniff，间隔 ~14ms 是否与 macOS 的默认 HID sniff 参数一致？

### 方向 C：绕开系统 HID 驱动，直接写 L2CAP 中断通道（Linux 的做法）

1. `IOBluetooth` 框架能否拿到**已经由系统打开的** HID 中断通道（PSM 0x13）对象并 `writeAsync`？（例如 `IOBluetoothDevice` 的 L2CAP 通道打开通知、`IOBluetoothL2CAPChannel` 的注册方法）。如果拿不到，能否再打开一个？会不会与系统 HID 驱动冲突？
2. 如果必须让系统 HID 驱动放手：代价是什么（输入也要自己解析并重新注入？`IOHIDUserDevice` 虚拟设备能否让游戏照常识别手柄？）需要什么权限 / 授权？
3. 写一个**最小验证程序**：尝试获取 / 打开 DualSense 的 L2CAP 通道，按 10.667ms 节奏写 0x36 空报告，统计吞吐量。要能在本机直接编译运行，失败时打印清楚的错误码。

### 方向 D：Mac 专用驱动、补丁、现成软件（仓库作者提出）

1. Sony 是否有 macOS 驱动 / 固件工具 / SDK（例如 PS Remote Play for Mac 在蓝牙下是否支持手柄扬声器或 HD 震动？若支持，它是怎么做的）。
2. 第三方：Steam（Steam Input 在 macOS 上是否支持 DualSense 扬声器 / 蓝牙触觉）、模拟器或串流软件（Chiaki / chiaki-ng、Moonlight、PS Remote Play 开源实现等是否在 macOS 实现过蓝牙音频或触觉）、DriverKit / HIDDriverKit 驱动、`DS4Windows` / `DualSenseX` 类工具的 macOS 移植、GitHub 上任何 macOS DualSense 音频 / 触觉项目。
3. **DriverKit 方案**：用 HIDDriverKit 写一个匹配 DualSense 的 dext，能否控制报告的发送通道 / 时序？需要的 entitlement 能否以个人开发者身份申请？

### 方向 E：在 ~5 KB/s 内「低质量省流」（作为退路）

只有在 A–D 都无法提速时才考虑。

1. 手柄扬声器子包 0x13 的格式：Opus 帧是否必须 CBR 160 kbps / 200 字节？Opus 解码器本身能处理任意码率，**手柄是否接受更低码率的帧（例如 16–32 kbps 的 10ms 帧，20–40 字节）**？
2. 一个大报告里能否放**多个**扬声器子包（例如 0x39 547 字节里放多帧），从而降低每秒包数？子包头里的长度字段是否允许？手柄端的抖动缓冲有多大？
3. 估算：在 ~5 KB/s 内能达到的最好方案（码率、帧长、每秒包数、延迟），并说明这是否仍然需要「每 10.667ms 一包」的硬节奏。

## 5. 交付物

1. **`docs/research/bluetooth-audio-findings.md`**：逐方向的结论（可行 / 不可行 / 不确定）、依据链接、推荐路线；如果都不可行，明确写出原因。
2. **本机验证程序**放在 `docs/research/`（独立的 `.swift` 文件，`swiftc` 直接编译运行，不改 App 本身），每个程序开头注释写清：要验证什么、怎么运行、预期输出如何解读。
3. **本机操作步骤清单**（PacketLogger 抓包、Bluetooth Explorer 等），按「先做哪个、看到什么就继续 / 停止」组织成决策树。
4. 若找到可行路线：附一份实现草案（接入现有 `SpeakerFeed` / `DualSenseReport` / `ControllerSession` 的方式），但**不要直接改 App 代码**，等本机验证通过再说。

## 6. 注意

- 不要因为「Sony 官方说扬声器只支持 USB」就停下：Linux 社区已经做通了，问题只在 macOS 的发送通道。
- 引用资料请附链接和具体位置（文件 / 行号 / 文档段落）；推测要明确标注是推测。
- 安全：验证程序不能对手柄做破坏性操作（不刷固件、不写特征报告里的配置），空报告或静音报告即可；涉及修改系统 Bluetooth 配置的步骤，要写明如何恢复。
