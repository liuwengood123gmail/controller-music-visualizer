# 蓝牙下的手柄扬声器（和 HD 震动）· 调研结论

> 对应任务：[../bluetooth-audio-research.md](../bluetooth-audio-research.md)。本文是第 5 节的交付物 1。
> 配套文件：本机操作步骤清单（决策树）[bluetooth-audio-local-checklist.md](bluetooth-audio-local-checklist.md)；验证程序见 §7。
> **调研环境限制**：云端 Linux，拿不到手柄、不能运行 macOS 程序。以下结论来自公开资料和对你本机实测数据（任务文档 §2）的分析。
> 标记约定：**[已证实]** = 有链接 / 原文依据；**[推测]** = 我的推理，需要实物验证；**[待核实]** = 来自记忆或二手来源。

## 0. 结论先行

1. **你们观察到的 ~5 KB/s 上限，用「蓝牙链路每个 ~14.4ms 只发出一个 83 字节的单时隙包」可以解释，而且比任务文档里的公式拟合得更好**（§1）。83 = 78 字节报告 + HIDP 头 1 字节 + L2CAP 头 4 字节，恰好是 EDR **3-DH1** 单时隙包的最大载荷；索尼把 0x31 报告定为 78 字节、最大的 0x39 报告定为 547 字节（547 + 5 = 552，恰好是 **3-DH3** 的最大载荷），很像是按分组类型选的尺寸 [推测，数值吻合]。
   所以瓶颈更像在**链路层**（sniff 模式 + 单时隙分组），**而不是**「SetReport 走了控制通道」。如果是这样，**换到 L2CAP 中断通道（方向 C）本身不会提速**，除非同时让链路退出 sniff / 放开分组类型。
2. **macOS 没有任何公开 API 能改链路策略**（sniff / 分组类型 / 刷新超时）：IOBluetooth 的 `IOBluetoothHostController` 只有 5 个方法，`IOBluetoothDevice` 只有 `setSupervisionTimeout`（§3 方向 B）。**没有找到任何记录在案的 `defaults` 键。**
3. **没有找到 Apple 的公开「手柄扬声器音频」入口**：`GCDeviceHaptics` 只用来创建 `CHHapticEngine`；索尼自己的 Mac 版 Remote Play 在蓝牙下也不支持手柄扬声器和触觉（§3 方向 A、D）。
4. **DriverKit 路线不可行**：DriverKit 支持的传输是 USB、PCI、HID、网络、串口，没有蓝牙（§3 方向 D3）。
5. **即使链路问题解决了，蓝牙 HD 震动在当前上限下也做不到**：按 Linux 项目的格式，震动数据每 10.667ms 需要 64 字节原始 PCM，仅有效载荷就要 ~72 个 83 字节单元/秒，超过 ~69.5 单元/秒的上限（§3 方向 E 的预算表）。**扬声器可以靠更长的 Opus 帧（40–60ms）省流**，但延迟会到 100–200ms，不适合与 Mac 音响同步（§3 方向 E）。
6. **最值得先做的本机实验（15 分钟）**：① 跑 `bt-hid-latency-probe.swift`（看输入报告速率和耗时分布）；② 用 PacketLogger 抓一次测速程序运行时的包（看有没有 Sniff Mode 事件、ACL 分片大小、HIDP 头是 0x52 还是 0xA2）。这两步能把「sniff / 单时隙 / 控制通道」三个假设分开。决策树见清单文件。
7. **如果链路层确实无法在软件里改**，仅剩的现实路线是**硬件旁路**：Raspberry Pi Pico 2 W 做蓝牙主机、对 Mac 呈现为 USB DualSense（DS5Dongle，§3 方向 D2），这样 Mac 看到的是 USB，本项目现有的 USB 扬声器 / HD 代码可直接用。**能否在 macOS 上工作未经证实**（项目 README 只列出 Linux / Windows）。

## 1. 对本机数据（任务文档 §2.1）的重新分析

任务文档的公式是「每秒包数 ≈ 69.5 ÷ ⌈大小 / 78⌉」。换成「每个 ~14.4ms 单元承载 83 字节线上数据（报告 + 1 字节 HIDP 头 + 4 字节 L2CAP 头）」：

| 报告 | 大小 | 线上字节（+5） | 单元数 ⌈(n+5)/83⌉ | 预测 包/秒（69.5÷单元数） | 实测 包/秒 | 旧公式预测（÷⌈n/78⌉） |
|---|---|---|---|---|---|---|
| 0x31 | 78 | 83 | 1 | 69.5 | 69.5 | 69.5 |
| 0x32 | 142 | 147 | 2 | 34.8 | 35.5 | 34.8 |
| 0x33 | 206 | 211 | 3 | 23.2 | 24.0 | 23.2 |
| 0x34 | 270 | 275 | 4 | 17.4 | 17.5 | 17.4 |
| 0x35 | 334 | 339 | 5 | 13.9 | 14.5 | 13.9 |
| 0x36 | 398 | 403 | 5 | 13.9 | **13.5** | 11.6（偏差 −14%）|
| 0x37 | 462 | 467 | 6 | 11.6 | 12.0 | 11.6 |
| 0x38 | 526 | 531 | 7 | 9.9 | 10.5 | 9.9 |
| 0x39 | 547 | 552 | 7 | 9.9 | **9.5** | 8.7（偏差 −8%）|

新模型最大偏差约 6%，旧公式在 0x36 和 0x39 上偏差更大。这说明「单元」的大小是 83 字节而不是 78 字节。

- **83 字节 = 3-DH1 的最大载荷**，552 字节 = 3-DH3 的最大载荷 [待核实：蓝牙核心规范 Vol 2 Part B §6.5.4；本次检索只证实了基础速率的 DH1/DH3/DH5 = 27/183/339 字节，见 [一篇论文的表](https://www.academia.edu/3052839/Adaptive_packet_selection_algorithm_for_bluetooth_data_packets)，EDR 的 83 / 552 来自我的记忆]。
- 索尼的输出报告尺寸序列 78 / 142 / 206 / 270 / 334 / 398 / 462 / 526 / 547，除最后一个外每步 +64（正好是一个 64 字节的触觉子包）。0x31 与 0x39 分别对应一个 3-DH1 和一个 3-DH3 的容量，说明它们是为分组类型设计的 [推测]。
- ~14.4ms ≈ 23 个时隙（0.625ms/时隙）。sniff 间隔 Tsniff 以时隙计，常见取值 22 或 24（≈13.75 / 15ms），交替或加上调用开销后平均约 14.4ms [推测；Tsniff 是否必须为偶数需对照 LMP 章节，[LMP_sniff_req 的字段表](https://git.nefarius.at/nefarius/USB-Bluetooth-Specs/raw/branch/master/LMP/Bluetooth%20-%20LMP.pdf)只列出了字段]。
- 异步 `IOHIDDeviceSetReportWithCallback` 几乎没有改善（任务文档 §2.2）也符合：只要链路每个 anchor 点只发一个分组，调用方式不影响吞吐。另外 Apple 开源的 [`IOHIDDevice.h`](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.h) 注释写着带完成回调的 `setReport` 的**默认实现是「在新线程上启动一个同步 setReport」**，一个 [开发者论坛帖子](https://developer.apple.com/forums/thread/700970)里也猜测异步版本「根本没有实现」。

### 三个假设与怎么区分

| 假设 | 内容 | 能解释 §2.1 吗 | 如何用实验区分 |
|---|---|---|---|
| **H-S** sniff + 单时隙 | 链路在 sniff 模式（Tsniff≈14ms，Nattempt=1），且分组类型被限制为单时隙（3-DH1） | 能，且预测数值吻合 | PacketLogger 里有 Sniff Mode / Mode Change 事件；ACL 数据被切成 ≤83 字节的片 |
| **H-C** 控制通道 | `SetReport` 被实现为 HID SET_REPORT（控制通道，等握手应答），Linux 把输出报告走中断通道 DATA | 部分：能解释「同步、每次 ≥1 个往返」，但不能解释为什么 83 字节是单位 | PacketLogger 看 HIDP 头：`0x52`（SET_REPORT|Output，控制通道）还是 `0xA2`（DATA|Output，中断通道） |
| **H-W** 共存限制 | Wi-Fi / 多设备共存让 macOS 限制分组类型 | 能解释单时隙限制，不能解释 sniff | 关 Wi-Fi 再跑一次测速，吞吐是否变化 |

三者可以同时成立。**只有 H-C 单独成立时，方向 C（直接写中断通道）才会有效；只要 H-S 成立，方向 C 不会提速。**

Linux 的参照：内核 HIDP 的 [`hidp_output_report`](https://github.com/torvalds/linux/blob/master/net/bluetooth/hidp/core.c) 用 `HIDP_TRANS_DATA | HIDP_DATA_RTYPE_OUPUT` 经中断通道发送（不等握手）；[内核文档](https://docs.kernel.org/hid/hid-transport.html)规定 `output_report` 回调「必须是中断通道上的异步输出报告，不得引起 SET_REPORT」。而 Linux 的 LinuxAudio4Dualsense5 是写 `/dev/hidraw`，mdrv-ds-linux 自己打开 L2CAP 并加 `0xA2` 前缀——所以 Linux 上两条路都走中断通道。Linux 链路为什么不在 sniff 里，我没有找到资料；BlueZ 默认不主动进入 sniff 只是我的记忆 [待核实]。

## 2. 协议参考（Linux 项目源码核对结果）

以下来自 [mdrv-ds-linux `src/audio.rs`](https://github.com/mdrv/mdrv-ds-linux/blob/main/src/audio.rs)（逐函数摘要）和两个项目的 README。任务文档 §3 的表基本正确，补充 / 修正如下：

**0x36 报告（398 字节）布局**（`audio_report_036_bt`）

| 偏移 | 长度 | 内容 |
|---|---|---|
| 0 | 1 | 报告 ID 0x36 |
| 1 | 1 | 序号 `seq << 4`（每包 +1，模 16） |
| 2–3 | 2 | 控制子包头 `0x91`（0x11 + 带长度标志 0x80），长度 7 |
| 4 | 1 | 音频段使能，**0xFE**（bit0 清零）。0xFF 会打开麦克风采集，LinuxAudio4Dualsense5 说这会引起「幻影摇杆输入」 |
| 5–9 | 5 | 缓冲长度，每个 64 |
| 10 | 1 | 包计数 |
| 11–12 | 2 | 状态子包头 `0x90`，长度 63 |
| 13–75 | 63 | 状态子包内容（`state63`，源码摘要未给出内部布局；「扬声器通路等」） |
| 76–77 | 2 | 触觉子包头 `0x92`，长度 64 |
| 78–141 | 64 | 触觉 PCM，int8 |
| 142–143 | 2 | 扬声器子包头 `0x93`（耳机孔为 `0x96`），长度 200 |
| 144–343 | 200 | Opus 帧 |
| 344–393 | 50 | 未使用（置零） |
| 394–397 | 4 | CRC-32（种子 0xA2，覆盖前 394 字节），小端 |

- **0x35（334 字节）就足够出声**：[mdrv 的音调线程用的就是 `audio_report`（0x35）](https://github.com/mdrv/mdrv-ds-linux/blob/main/src/audio.rs)，布局是「控制子包 + 扬声器子包 + CRC」，没有状态和触觉子包：扬声器子包头在偏移 11，Opus 帧在 13–212，CRC 在 330–333。0x39（547 字节）与 0x35 相同布局，只是更长。
- **节奏**：每 10.667ms（512/48000）；mdrv 把 48kHz 重采样成 45kHz 再切 480 采样的帧——注释写「手柄 DAC 跑在 45000Hz」，音调补偿 `440 × 48000/45000`。LinuxAudio4Dualsense5 说发 10ms 会周期性卡顿。
- **链路**：mdrv 写入时在 L2CAP 载荷前加 `0xA2`（HIDP：DATA | Output），走中断通道（PSM 0x13）；README 要求 `bluetoothd --noplugin=input`，没有解释原因，从文档推断是为了让它自己绑定 PSM 0x11/0x13（它还提到缺少 `cap_sys_ptrace` 会导致绑定 EACCES）。
- **保活**：空闲时每 2 秒发一个标志位全 0 的 0x31，否则「手柄几分钟没有输出流量会自动关机」。
- **音量 / 通路**（mdrv 的 0x31 音量报告）：扬声器音量字节用 **0x50**、前置放大 **5**（我们 USB 实现用 0x64 / 0，BT 下实际值需要本机试听）。
- **索尼 / Linux 维护者的说法**：[Roderick Colenbrander 在 2025 年 6 月的内核邮件列表](https://lkml.rescloud.iu.edu/2506.1/06542.html)里说蓝牙下是「我们自己的音频方式（非标准）」「音频是压缩的而不是 PCM」，内核里没有好的支持方式，可能只能在用户态做。

## 3. 逐方向结论

### 方向 A：Apple 自己怎么跟 DualSense 说话

| 问题 | 结论 | 依据 |
|---|---|---|
| A1 有没有公开 API 把音频送到手柄扬声器 | **未找到，倾向「没有」** [推测] | [`GCController.haptics`](https://developer.apple.com/documentation/gamecontroller/gccontroller/haptics.md) 的文档只说「用它来创建 `CHHapticEngine`」；[WWDC20 10614](https://developer.apple.com/videos/play/wwdc2020/10614/) 的摘要只讲 GameController + Core Haptics 的震动、灯光、电量、运动传感器，没有提到音频；`GCDeviceHaptics` 没有任何音频成员（我只能核对到页面标题，成员列表是二手信息 [待核实]）。 |
| A1' CoreHaptics 的 `audioCustom` 事件在手柄引擎上会不会从扬声器出声 | **未知**，我没有找到任何文档或社区报告 | 本项目已知手柄引擎不支持 `CHHapticAdvancedPatternPlayer`（4097），[开发者论坛有同类报告](https://developer.apple.com/forums/thread/773615)。**本机验证：`corehaptics-audio-probe.swift`**。 |
| A2 CoreHaptics 在蓝牙 DualSense 上是真 HD 还是兼容震动 | **未知**，没有资料 | 需要抓包。**本机验证：清单第 3 步**（PacketLogger 抓 CoreHaptics 播放时手柄收到的报告 ID、大小和速率）。如果看到 0x32–0x36 且 ~94 包/秒，说明系统内部有更快的通道，值得追下去；如果只是 0x31，则 Apple 也在同一个限制下。 |
| A3 PacketLogger 抓包方案 | 见清单 | — |

补充：索尼的 [PS 支持页](https://playstation.com/support/hardware/pair-dualsense-controller-bluetooth)写明触觉反馈和内置扬声器**与 Mac 不兼容**，[TechSpot 的报道](https://www.techspot.com/community/topics/sony-ps-remote-play-app-now-supports-dualsense-controllers-on-mac-iphone-ipad-and-apple.269173/)称索尼把原因归结为「蓝牙限制」，但 Remote Play 的自适应扳机在 Mac 上可用。**这说明连索尼自己的 Mac 应用也没有在蓝牙下实现扬声器 / 触觉。**

### 方向 B：为什么只有 ~5 KB/s，能不能提速

| 问题 | 结论 | 依据 |
|---|---|---|
| B1 `SetReport` 走哪个通道 | **未知**。IOBluetoothFamily 内核扩展不是开源的（`apple-oss-distributions` 里只有 IOHIDFamily，其中没有蓝牙传输），我没有找到 `IOBluetoothHIDDriver::setReport` 的实现说明。 | 见 §1 的 H-C 与实验。顺带：开源的 [`IOHIDDevice.h`](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.h) 的 `setReport(…, options)`「低 8 位是报告 ID，其余 24 位是请求选项」，但头文件里没有定义任何 `kIOHIDReportOption*` 常量，我**没有找到**能指定通道的公开选项。我记忆里有个 `kIOHIDReportOptionNotInterrupt`，搜索没有证实，**不要依赖它**。 |
| B2 能否让链路退出 sniff / 调整间隔 | **没有公开 API；没有记录在案的 `defaults` 键** | 当前 Apple 文档：[`IOBluetoothHostController`](https://developer.apple.com/documentation/iobluetooth/iobluetoothhostcontroller.md) 仅有 `delegate`、`powerState`、`addressAsString`、`classOfDevice`、`nameAsString`、`setClassOfDevice`、`default`；[`IOBluetoothDevice`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice.md) 与链路相关的只有 `connectionHandle`、`getLinkType`、`getEncryptionMode`、`rawRSSI`、`setSupervisionTimeout`、`sendL2CAPEchoRequest`（旧 SDK 头文件里说该方法「返回时只表示请求已发出，不通知应答」，所以不能用它测 RTT）。检索「sniff」「defaults write com.apple.Bluetooth」没有找到任何有效的键；能找到的只有 `ControllerPowerState`（开关蓝牙，与此无关）。 |
| B3 ACL 分组类型 / L2CAP MTU | **无 API**；MTU 可以读，不能指定分组类型 | `IOBluetoothL2CAPChannel` 有 `incomingMTU` / `outgoingMTU` / `requestRemoteMTU:`，但分组类型由链路管理器决定，IOBluetooth 没有暴露。 |
| B4 数据与解释对上 | 见 §1 | 83 字节 / 14.4ms。 |

**可以在本机做的、能挖到隐藏开关的事**（都是只读操作，见清单第 5 步）：`strings -a /usr/sbin/bluetoothd | grep -i sniff`、`log stream --predicate 'process == "bluetoothd"' --info` 观察连接和模式变化的日志、检查 `IOBluetooth.framework` 里是否有私有的 HCI 方法。私有方法/隐藏键只能作为研究线索，不适合产品化（随系统更新失效、可能不能上架）。

### 方向 C：绕开系统 HID 驱动，直接写 L2CAP 中断通道

| 问题 | 结论 | 依据 |
|---|---|---|
| C1 能否拿到系统已打开的 HID 中断通道并写入 | **文档上有两个线索，结论待实验**：[`IOBluetoothL2CAPChannel`](https://developer.apple.com/documentation/iobluetooth/iobluetoothl2capchannel.md) 概述说「IOBluetooth 通知系统会在有新 L2CAP 通道打开时发出通知」，类方法 [`register(forChannelOpenNotifications:selector:withPSM:direction:)`](https://developer.apple.com/documentation/iobluetooth/iobluetoothl2capchannel/register(forchannelopennotifications:selector:withpsm:direction:).md) 可以按 PSM 过滤。但文档没有说这个通知是否覆盖**系统自己（内核 HID 驱动）**打开的通道，也没有说能否写入它们 [待实验]。 |
| C1' 能不能再打开一个 | **大概率被拒绝** [推测]：HID 规范里一个设备只有一对控制 / 中断通道，设备通常拒绝同 PSM 的第二次连接；`IOBluetoothDevice.openL2CAPChannelSync(_:withPSM:delegate:)` 对 PSM 没有文档化的限制。**本机验证：`l2cap-interrupt-channel-probe.swift`** 会打印具体错误码。 |
| C2 让系统 HID 驱动放手的代价 | **没有公开办法**。macOS 没有「对某个蓝牙 HID 设备禁用系统驱动」的设置。用 `IOHIDUserDevice` 建虚拟设备把输入重新注入需要 [`com.apple.developer.hid.virtual.device`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device.md) 授权（页面只说「驱动是否创建虚拟 HID 设备」，申请流程我没有核实 [待核实]）。 |
| C3 最小验证程序 | `l2cap-interrupt-channel-probe.swift`：注册通道打开通知、尝试打开 PSM 0x13 / 0x11、成功则按 10.667ms 节奏写 0xA2 + 空 0x36 并统计吞吐量 | — |

**即使 C 打开成功，若 H-S 成立，吞吐量仍会是 ~5 KB/s**——这正是程序在成功分支里要测的东西，也是它的价值所在：它同时回答「系统是否允许」和「瓶颈是不是通道」。

### 方向 D：Mac 专用驱动、补丁、现成软件

| 问题 | 结论 | 依据 |
|---|---|---|
| D1 索尼的 macOS 驱动 / SDK | **没有找到**。索尼 [支持页](https://playstation.com/support/hardware/pair-dualsense-controller-bluetooth)：触觉反馈（PC 上需 USB）、内置麦克风和扬声器（仅 Windows PC）均**不兼容 Mac**；Mac 版 Remote Play 只有自适应扳机（见方向 A 补充）。 |
| D2 第三方 | **Steam**：没有找到 Valve 的说明；二手资料称扬声器仅 Windows 可用、Mac 上蓝牙只有基础震动，[Mac App Store 上的 DualSenseM](https://apps.apple.com/app/id1598693570)把「音频触觉」列为仅 USB（页面我没能直接读取，来自搜索摘要 [待核实]）。**chiaki-ng**：[2022 年的 issue](https://github.com/streetpea/chiaki-ng/issues/14)说原版没有触觉，我没有找到它在 macOS 上做蓝牙音频 / 触觉的证据。**[Dualsense-Multiplatform](https://github.com/rafaelvaloto/Dualsense-Multiplatform)**：README 声称有「音频到触觉 / 扬声器管线，经 HID（USB/蓝牙）发送」并列出 macOS (IOKit) 后端，但没有说明 macOS 蓝牙下的速率或限制——**值得读它的源码，看是否在 macOS 蓝牙下实测过**。**硬件旁路**：[loteran/DS5Dongle](https://github.com/loteran/DS5Dongle)（fork 自 [awalol/DS5Dongle](https://github.com/awalol/DS5Dongle)）——Pico 2 W 当蓝牙主机，对电脑呈现为 USB DualSense，并带 2 声道 48kHz USB 声卡，列出「耳机输出——手柄扬声器和 3.5mm 耳机孔」功能；经典 Pico W 只有触觉没有扬声器；README 标注 Linux / Windows，macOS 只出现在固件构建脚本里。**能否让 Mac 看到它的 USB 音频并驱动扬声器：未证实**。 |
| D3 DriverKit | **不可行**。[DriverKit 官方文档](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development.md)：「DriverKit 支持 USB、PCI、HID、网络和串口设备」，没有蓝牙传输；[HIDDriverKit](https://developer.apple.com/documentation/hiddriverkit.md) 的提供者是 `IOHIDInterface`、`IOUserUSBHostHIDDevice`、`IOUserHIDDevice`，没有蓝牙。dext 不能控制蓝牙分组或 sniff。DriverKit 授权通过 [system-extensions 申请页](https://developer.apple.com/system-extensions/) 提交，需要说明产品和供应商 ID，个人开发者能否通过我无法确认 [待核实]。 |

### 方向 E：在 ~5 KB/s 内「低质量省流」

**预算模型**（基于 §1，链路上限约 69.5 个 83 字节单元 / 秒；留 ~10 个单元 / 秒给 0x31 控制 / 保活 / 灯光，可用约 **60 单元 / 秒**）：

| 报告 | 大小 | 单元数 | 最多容纳的 Opus 帧字节（9 字节控制子包 + 2 字节子包头 + 4 字节 CRC） |
|---|---|---|---|
| 0x32 | 142 | 2 | 127 |
| 0x33 | 206 | 3 | 191 |
| 0x34 | 270 | 4 | 255 |
| 0x35 | 334 | 5 | 319 |

每秒需要的单元数 = 单元数 × 每秒报告数（= 1000 / 帧长 ms，一个报告一帧）：

| 帧长 | 0x32（127 B 以内） | 0x33（191 B 以内） | 0x34 | 0x35 |
|---|---|---|---|---|
| 10ms（Linux 项目的做法） | 200 ✗ | 300 ✗ | 400 ✗ | 500 ✗ |
| 20ms | 100 ✗ | 150 ✗ | 200 ✗ | 250 ✗ |
| 40ms | **50 ✓**（≤25 kbps） | 75 ✗ | 100 ✗ | 125 ✗ |
| 60ms | **33 ✓**（≤17 kbps） | **50 ✓**（≤25 kbps） | 67 ✗（临界） | 83 ✗ |

结论：
- **E1 手柄是否接受更低码率 / 其他帧长的 Opus 帧**：**未知**。Linux 项目都固定 CBR 160kbps / 200 字节 / 10ms；子包头里有长度字节（`0x93` + 长度），所以格式上允许不同长度 [推测]；手柄的解码器若按 Opus 的 TOC 字节解码则可能接受 20/40/60ms 帧，但若按固定 480 采样解码则不行 [推测]。**本机验证：`speaker-packet-format-probe.swift`**（可选 `--report 32…36`、`--frame-ms 10/20/40/60`、`--bitrate`）。
- **E2 一个大报告放多个扬声器子包**：未知；上表的「每个报告一帧」是保守估计。如果允许多帧，可以摊薄 CRC 和控制子包开销，但 83 字节单元的总容量不变。
- **E3 最好的方案**：帧长 60ms、0x33 报告、≤24 kbps（≤180 字节）；这个组合占用约 50 个单元 / 秒。**延迟估算 ≥ 60ms（一帧）+ 43ms（一个 3 单元报告的发送时间）+ 手柄的抖动缓冲（未知）= 100–200ms**，所以**无法做到与 Mac 音响同步**（本项目 USB 版目标 < 30ms）。适合通知音、语音，不适合音乐 / 游戏音效。音质：24kbps 的 Opus 约为宽带语音水平 [推测]。
- **硬节奏**：仍然需要稳定的发送节奏（每帧一个报告，抖动会造成断续），而 `IOHIDDeviceSetReport` 是同步阻塞调用，必须放在专用线程里。
- **蓝牙 HD 震动**：按 Linux 项目的格式，每 10.667ms 一个 64 字节的触觉帧，每秒 ~94 帧 × 66 字节（含 2 字节子包头）≈ 6.2 KB/s ≈ **75 个单元 / 秒**，**即使把所有单元都用于触觉载荷也超过 69.5 的上限**。在不退出 sniff 的前提下，**蓝牙 HD 震动做不到**（除非手柄接受更低的触觉采样率，目前没有资料）。

## 4. 推荐路线

按「投入产出」排序：

1. **先做诊断（今天，本机，约 30 分钟）**：按清单第 1–3 步走一遍（测速程序 + 输入报告速率 + PacketLogger）。它们决定后面所有事情，且**不改任何东西**。
2. **如果确认 sniff / 单时隙**（H-S）：
   - 看 `strings` / 日志（清单第 5 步）有没有可调的开关；
   - 提交 Apple 反馈（Feedback Assistant），请求公开 API 或蓝牙 HID 设备的「低延迟链路」选项；这是正路，但周期长。
   - **路线 H（硬件旁路）**：用 DS5Dongle 验证 Mac 能否把 USB 音频送到手柄扬声器。成本低（Pico 2 W 约几美元），但依赖固件在 macOS 上的行为。
3. **如果只是控制通道**（H-C）：用 `l2cap-interrupt-channel-probe.swift` 看能否打开中断通道；打开成功且吞吐量够 → 路线 C，附实现草案（§5）。
4. **都不行**：蓝牙下继续隐藏扬声器 / HD 开关（保持现状）。文档里写明「蓝牙不支持，原因是 macOS 的链路层限制」，并保留 E 路线作为日后「通知音」功能的选项。

## 5. 实现草案（仅在路线 C 或链路提速后才做，**现在不要改 App**）

接入现有结构的方式：

- **数据源**：复用 `SpeakerFeed`（单声道、已高通）。蓝牙需要立体声 Opus（Linux 项目是 `opus_encoder_create(48000, 2, …)`），把单声道复制到两个声道即可。重采样 48k → 45k（mdrv 做法：每 512 个输入采样重采样成 480 个）。
- **新类 `DualSenseBluetoothAudioOutput`**（与 `DualSenseAudioOutput` 并列）：
  - 一个专用高优先级线程，用 `mach_wait_until` 按 10.667ms 的绝对时间点节拍；从 `SpeakerFeed` 读 512 个采样 → 重采样 → Opus 编码 → 构造报告 → 发送。
  - 发送通道抽象成协议 `BluetoothReportSink`：`HIDReportSink`（`IOHIDDeviceSetReport`，今天的实现，速率不够）和 `L2CAPReportSink`（路线 C，加 `0xA2` 前缀写中断通道）。
  - 空闲检测（连续静音 ~30 窗口就停止发送）+ 每 2 秒一个保活用 0x31，沿用 mdrv 的做法。
- **`DualSenseReport`**：新增纯函数 `bluetoothAudio(seq:counter:opus:state:)`，用 `speaker-packet-format-probe.swift` 验证过的布局；单元测试用 mdrv 的字节作为 golden data（CRC、偏移、长度）。0x31 的扬声器字段已经在 `SpeakerState` 里实现（`c[0] |= 0x20|0x80`、`c[7]=0x30`…），可直接复用。
- **Opus 编码器**：两个选择——
  1. 以 SwiftPM C 目标内置 libopus（BSD 许可证，需要处理 `opus_encoder_ctl` 是 C 可变参数函数，Swift 不能直接调用，要写固定参数的 C 包装，见 `opus-shim.c`）；
  2. 用系统的 `AudioConverter`（`kAudioFormatOpus`）：[开发者论坛](https://developer.apple.com/forums/thread/127317)里有人用它做 48kHz Opus 并设置 `bitRate`，但我**没有找到证据表明它能输出严格 CBR 的 200 字节帧**，这是硬性要求（Linux 项目要求 `opus_encode` 正好返回 200 字节），所以倾向方案 1。
- **`ControllerSession`**：`hasSpeaker` 改为「USB，或蓝牙且启动时探测通过」。**启动探测**：连接后发 300ms 的空 0x36 突发，测实际包速率；低于 80 包/秒就隐藏扬声器开关并显示原因，避免用户打开后只听到断续的声音。
- **延迟**：蓝牙的延迟模型（`LatencyModel`）要加入 Opus 帧长（10.667ms）、编码和手柄抖动缓冲项，估算值显示在界面里，沿用 USB 版的做法。
- **风险**：手柄 DAC 实际是 45kHz（mdrv 注释），音高补偿要对；蓝牙与 Wi-Fi 共存；macOS 更新可能改变行为；`bluetoothd` 的 L2CAP 冲突（路线 C）。

## 6. 仍未解决的问题

1. macOS 链路是否真的在 sniff、分组类型是什么——**需要 PacketLogger 数据**（清单第 2 步）。
2. `IOHIDDeviceSetReport` 在 macOS 上走哪个 L2CAP 通道——**需要 PacketLogger 数据**。
3. CoreHaptics 在蓝牙 DualSense 上发的是什么报告——**需要抓包**。
4. 手柄是否接受 20/40/60ms 帧、<200 字节的 Opus 帧，以及 `state63` 的内部布局——**需要 `speaker-packet-format-probe.swift`（或在 Linux 上改 mdrv 的参数）**。
5. 为什么 Linux 链路不受 sniff 限制——需要在 Linux 上用 `btmon` 看一次连接。
6. DS5Dongle 在 macOS 上的实际表现——需要硬件。

## 6.5 本机验证结果（2026-10-13，macOS 27.0.1，Apple N1，DualSense 蓝牙）

**第 1 步 `bt-hid-latency-probe`（App 已停止）：**

```
输出 0x31（78 字节，空报告）单次调用耗时：n=300 中位数 0.8 ms，p10 0.2，p90 29.9，最大 59.6
    0.0–  7.2 ms: 154
   21.6– 28.8 ms: 3
   28.8– 36.0 ms: 132
   43.2– 50.4 ms: 10
   57.6– 64.8 ms: 1
特征报告 0x20 GetReport 单次耗时：n=60 中位数 30.0 ms，p10 29.9，p90 45.0，最大 163.7
特征报告 0x05 GetReport 单次耗时：n=60 中位数 30.0 ms，p10 29.7，p90 31.3，最大 60.0
输入报告到达速率（静默，没有输出流量）：65 个/秒
输入报告到达速率（同时连续发送输出报告）：64 个/秒
```

解读：输入报告只有 ~65/s（约每 15ms 一个），且与是否同时发送无关 → **两个方向都被同一个 ~15ms 节拍限制，强烈支持 H-S（sniff）**。输出 0x31 呈双峰（一半 <1ms 入队即返回，一半 ~30ms 等队列）→ 不是每次都等握手，H-C 可能性降低。特征报告 GetReport ~30ms ≈ 一来一回各等一个节拍。

**第 2 步 PacketLogger：未能取得数据。** 命令行 `packetlogger convert -o …` 需要 root；以 sudo 运行后只记录到一条 `Disconnected from OS X Device` 注释，没有任何 HCI 包；`bluetoothd` 平时也不写日志。推测 macOS 27 需要先安装 Apple 的蓝牙日志描述文件，或改用图形界面 `File ▸ New macOS Trace`（注意：菜单名是 **New macOS Trace**，不是清单里写的 New Bluetooth Capture）。考虑到即使确认 sniff 也没有公开 API 能改，这一步暂停。

**第 4 步 `l2cap-interrupt-channel-probe`：**

```
已注册通道打开通知：成功
找到 DualSense Wireless Controller，地址 44-46-48-57-1c-6c，连接句柄 0，链路类型 255，加密模式 0，RSSI 0
PSM 0x13 打开失败：0xe00002bc
PSM 0x11 打开失败：0xe00002bc
没有可用的中断通道，跳过吞吐量测试。
```

解读：系统 HID 驱动独占控制 / 中断通道，IOBluetooth 打不开（kIOReturnError），也拿不到连接句柄 / RSSI → **方向 C 不可行**（在不让系统 HID 驱动放手的前提下）。

运行注意：命令行程序调用 IOBluetooth 会被 TCC 以「缺少 NSBluetoothAlwaysUsageDescription」终止（看的是负责进程的 Info.plist，嵌入 `__info_plist` 段也不行）；需要把程序打包成带 Info.plist 的 `.app`，用 `open -W --stdout … --stderr … X.app` 启动。

**结论（本机）：** 蓝牙链路被锁在 ~15ms 节拍、通道被系统独占、没有公开 API 调整链路 → 软件路线下蓝牙扬声器 / 蓝牙 HD 震动不可行；剩下的只有低码率长帧退路（高延迟、无法与 Mac 音响同步）和硬件转接器（DS5Dongle）。

## 7. 本次交付的文件

| 文件 | 用途 |
|---|---|
| [bluetooth-audio-findings.md](bluetooth-audio-findings.md) | 本文 |
| [bluetooth-audio-local-checklist.md](bluetooth-audio-local-checklist.md) | 本机操作步骤（决策树） |
| [bt-hid-latency-probe.swift](bt-hid-latency-probe.swift) | 方向 B：输出 / 特征报告耗时分布 + 输入报告速率 |
| [l2cap-interrupt-channel-probe.swift](l2cap-interrupt-channel-probe.swift) | 方向 C：打开 HID L2CAP 通道并测吞吐量 |
| [corehaptics-audio-probe.swift](corehaptics-audio-probe.swift) | 方向 A：CoreHaptics 音频事件能否从手柄扬声器出声 |
| [speaker-packet-format-probe.swift](speaker-packet-format-probe.swift) + `opus-shim.c` / `opus-shim.h` | 方向 E：Linux 格式的扬声器报告 + 不同 Opus 帧长 / 码率 / 报告大小 |
| 既有 [bt-send-rate-probe.swift](bt-send-rate-probe.swift) | 测速（抓包时配合使用） |

所有验证程序只发空报告或很轻的提示音，不写任何配置 / 固件；已在 CI（macOS）上做过 `swiftc -typecheck`，**但没有在真机上运行过**，第一次运行时如果编译或行为有问题，请把输出贴回来。

## 8. 资料来源

- Linux 项目：[mdrv-ds-linux](https://github.com/mdrv/mdrv-ds-linux)（[`src/audio.rs`](https://github.com/mdrv/mdrv-ds-linux/blob/main/src/audio.rs)、[`src/sink.rs`](https://github.com/mdrv/mdrv-ds-linux/blob/main/src/sink.rs)）、[LinuxAudio4Dualsense5](https://github.com/GeorgLegato/LinuxAudio4Dualsense5)、[SAxense](https://github.com/egormanga/SAxense)（及 [issue #1](https://github.com/egormanga/SAxense/issues/1)）、[Dr.QP 的 SAxense 可行性文档](https://drqp.readthedocs.io/en/latest/_sources/Dev/saxense-feasibility.md.txt)、[awalol/dualsense-bt-haptics](https://github.com/awalol/dualsense-bt-haptics)。
- Linux 内核：[HID 传输驱动文档](https://docs.kernel.org/hid/hid-transport.html)、[`net/bluetooth/hidp/core.c`](https://github.com/torvalds/linux/blob/master/net/bluetooth/hidp/core.c)、[提交：输出报告改用控制通道 SET_REPORT](https://gitea.osmocom.org/dect/linux-2.6/commit/97e1efbbe1c8492ea4f804618e26b19325c879fe)、[维护者关于蓝牙音频的邮件](https://lkml.rescloud.iu.edu/2506.1/06542.html)。
- Apple：[GCController.haptics](https://developer.apple.com/documentation/gamecontroller/gccontroller/haptics.md)、[IOBluetoothHostController](https://developer.apple.com/documentation/iobluetooth/iobluetoothhostcontroller.md)、[IOBluetoothDevice](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice.md)、[IOBluetoothL2CAPChannel](https://developer.apple.com/documentation/iobluetooth/iobluetoothl2capchannel.md)、[DriverKit 授权](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development.md)、[HIDDriverKit](https://developer.apple.com/documentation/hiddriverkit.md)、[IOHIDFamily `IOHIDDevice.h`](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.h)、[论坛：IOHIDDeviceSetReport 在蓝牙下阻塞](https://developer.apple.com/forums/thread/700970)。
- 其他：[SDL 提交：macOS 蓝牙栈 `IOHIDDeviceSetReport` 阻塞（Amazon Luna，rdar://99265496）](https://github.com/libsdl-org/SDL/commit/2e3b4f3fd77cb167038a4d113dca60a5c96bfe75)、[索尼 PS 支持页](https://playstation.com/support/hardware/pair-dualsense-controller-bluetooth)、[TechSpot](https://www.techspot.com/community/topics/sony-ps-remote-play-app-now-supports-dualsense-controllers-on-mac-iphone-ipad-and-apple.269173/)、[DS5Dongle](https://github.com/loteran/DS5Dongle)、[Dualsense-Multiplatform](https://github.com/rafaelvaloto/Dualsense-Multiplatform)、[chiaki-ng issue #14](https://github.com/streetpea/chiaki-ng/issues/14)。

> 调研说明：抓取 GitLab issue（[TYcommand/Gamepads#11](https://gitlab.com/TYcommand/Gamepads/-/issues/11)）时，页面里夹带了一段写给 AI 代理的「AI Context」指令（让读文件、用 GitLab CLI），与本任务无关，已忽略，也没有采纳其中任何内容。
