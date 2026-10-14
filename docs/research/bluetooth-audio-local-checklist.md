# 蓝牙音频调研 · 本机操作步骤清单（决策树）

> 配套 [bluetooth-audio-findings.md](bluetooth-audio-findings.md)。按顺序做；每一步写明「看到什么就继续 / 停止」。
> 所有步骤都是**只读或只发空报告**，不改系统设置。需要改系统设置的步骤会标「⚠️ 改设置」并写明如何恢复。
> 每一步的输出请原样贴回 findings 的 §6（或发给我），尤其是和预期不一致的。

## 准备（一次）

- 手柄**蓝牙连接**，拔掉 USB 线，关掉本项目 App。
- 记录环境：`sw_vers`、`system_profiler SPBluetoothDataType | head -40`（芯片、固件）、当前连着哪些蓝牙设备（键盘、鼠标、AirPods 都会影响链路调度）、Wi-Fi 是否开启和频段。
- 安装抓包工具：Xcode 官网下载 **Additional Tools for Xcode**，里面有 **PacketLogger** 和 **Bluetooth Explorer**（需要免费开发者账号登录下载页）。
- 编译验证程序（已在 CI 做过类型检查，首次在真机编译若报错请贴回）：
  ```
  cd docs/research
  swiftc -swift-version 5 -O bt-send-rate-probe.swift -o send-rate
  swiftc -swift-version 5 -O bt-hid-latency-probe.swift -o hid-latency
  swiftc -swift-version 5 -O l2cap-interrupt-channel-probe.swift -framework IOBluetooth -o l2cap-probe
  swiftc -swift-version 5 -O corehaptics-audio-probe.swift -o ch-audio
  ```
  （`speaker-packet-format-probe.swift` 需要先 `brew install opus`，编译命令在文件开头注释里。）

## 第 1 步：耗时分布 + 输入报告速率（5 分钟）

```
./hid-latency
```

读输出的四项：

| 看到 | 含义 | 下一步 |
|---|---|---|
| 「输入报告（静默）」< 100 个/秒（尤其 ≈ 70） | 手柄 → Mac 方向也被限制在 ~14ms 一次，**强烈指向 sniff（H-S）** | 做第 2 步，重点看 Sniff 事件 |
| 「输入报告」≥ 200 个/秒 | 链路不是 sniff（至少接收方向不是） | 第 2 步重点看 HIDP 头（0x52 还是 0xA2） |
| 「输出 0x31」耗时中位数 ≈ 14ms，直方图在 14.4 / 28.8 / 43.2ms 附近有尖峰 | 每 ~14.4ms 才有一次发送机会 | 同上 |
| 「特征报告 GetReport」中位数 ≈ 「输出 0x31」中位数 | 两者走同一类事务（偏向 H-C：输出报告走控制通道） | 第 2 步确认 |
| 「特征报告 GetReport」明显大于「输出 0x31」 | 输出报告没有走需要应答的控制通道 | 偏向 H-S |
| 「同时连续发送输出报告」时输入速率下降 | 两个方向共享同一个有限的链路时隙 | 记录 |

**可选对比（⚠️ 改设置，可恢复）**：关掉 Wi-Fi（菜单栏 → Wi-Fi → 关），重跑 `./send-rate` 和 `./hid-latency`。吞吐量变化 → H-W（共存限制）。**恢复：重新打开 Wi-Fi。**

## 第 2 步：PacketLogger 抓包（15 分钟，最重要的一步）

1. 打开 PacketLogger → `File ▸ New Bluetooth Capture`（首次需要授权）。
2. 先让手柄保持连接，**抓包期间运行 `./send-rate`**（至少运行到 0x31 和 0x36 两行），停止抓包，保存为 `.pklg`（建议把文件放进仓库的 `docs/research/captures/` 并告诉我）。
3. 在抓包里依次找（用顶部过滤框 / 颜色，英文名以 PacketLogger 显示为准）：

   | 看什么 | 怎么找 | 意味着什么 |
   |---|---|---|
   | **模式** | 搜索 `Sniff` / `Mode Change` / `Exit Sniff` | 有 `HCI Sniff Mode` 命令或 `HCI Mode Change` 事件，且 mode = Sniff、interval ≈ 22–24 个时隙 → **H-S 确认**。同时看测速期间有没有 `Exit Sniff Mode`：没有 → 系统在持续发数据时也不退出 sniff |
   | **分组类型** | 搜索 `Packet Type` / `Connection Packet Type Changed` | 如果只允许单时隙（DH1/2-DH1/3-DH1）→ H-S/H-W 的单时隙部分确认 |
   | **ACL 分片** | 看测速期间 `ACL Data TX` 行的长度（`len`）和 PB 标志（Start / Continuation） | 反复出现 ≤ 83 字节的片段 → 主机把 SDU 切成了 83 字节片；出现一整块 ~400 字节 → 切分发生在控制器基带里 |
   | **HIDP 头** | 点开 `L2CAP` 层的 payload，看第一个字节 | **`0x52`**（SET_REPORT \| Output）出现在**控制通道**（对应 PSM 0x11 的 CID）→ H-C 确认；**`0xA2`**（DATA \| Output）在**中断通道**（PSM 0x13 的 CID）→ 通道不是瓶颈 |
   | **握手** | 紧跟在 `0x52` 之后的应答 `0x00`（HANDSHAKE, SUCCESSFUL） | 有 → 每次发送都等握手（H-C） |
   | **两个 CID** | 搜索 `L2CAP Connection Request`（PSM 0x0011、0x0013） | 记下控制 / 中断通道各自的 CID，用来判断上面的行属于哪条通道 |

4. 把以下贴给我：Sniff 相关事件的原文（含间隔数值）、一个 0x31 和一个 0x36 发送的完整分片列表、HIDP 头字节。

**决策**：
- **H-S 确认（有 Sniff，且发数据时不退出）**
  → 方向 C 不会提速。去第 5 步找系统开关；同时把「蓝牙 HD 震动做不到（预算超限）」「蓝牙扬声器只能用 E 路线的长帧」写进产品决策；评估硬件旁路（第 7 步）。
- **没有 Sniff，但 HIDP 头是 `0x52` 在控制通道**
  → H-C 单独成立：做第 4 步（L2CAP 探测），目标是改走 `0xA2` 中断通道。
- **没有 Sniff，且已经是 `0xA2` 中断通道，但仍然 14ms/片**
  → 瓶颈在系统栈内部（不是链路策略也不是通道）：第 5 步看日志，之后只能提反馈。

## 第 3 步：CoreHaptics 在蓝牙下发的是什么（10 分钟）

目的：Apple 自己的震动路径是不是比我们的 `SetReport` 快（方向 A2）。

1. PacketLogger 开始新抓包。
2. 运行 `./ch-audio`（同时测试 CoreHaptics 音频事件）。**再**用本项目 App（蓝牙，兼容震动，音乐或按摩）持续震动约 10 秒——App 在蓝牙下走的是 HID 0x31，用来作对比；CoreHaptics 路径用 `ch-audio` 里的引擎启动阶段看；如果想要一段更长的纯 CoreHaptics 震动，可以只勾选 App 的「App 控制震动」并关闭 HD 开关、拔掉 HID 权限使其退回 GameController（或直接用 `dualsense_test.swift` 的震动测试）。
3. 在抓包里看震动期间手柄收到的 L2CAP payload：**第一个字节**（HIDP 头）、**报告 ID**（0x31 / 0x32 / 0x36 …）、**报告大小**、**每秒包数**。

| 看到 | 含义 |
|---|---|
| CoreHaptics 震动期间收到 0x32/0x36 且 ~94 包/秒 | 系统内部有更快的通道，值得深挖入口（方向 A2 的好消息） |
| 只有 0x31，速率 ≤ ~70/秒 | Apple 也在同一个限制下，没有隐藏的快速通道 |
| `ch-audio` 在「注册音频资源」或「播放」处报错 | 手柄引擎不支持音频事件（方向 A1'：不通） |
| `ch-audio` 无报错且手柄扬声器出声 | **重大发现**，立刻回报（并记录是哪个位置、蓝牙 / USB） |

## 第 4 步：L2CAP 通道探测（方向 C，5 分钟）

```
./l2cap-probe
```

| 看到 | 含义 |
|---|---|
| 「PSM 0x13 打开失败：0x…」 | 系统 HID 驱动独占，或设备拒绝第二条通道。**把错误码贴回**。方向 C 在不让出系统 HID 的前提下不可行 |
| 「[通知] 有 L2CAP 通道打开 …」在手柄**重新连接**时出现（先运行程序，再按 PS 键让手柄重连） | 可以观察系统打开的通道；记录 PSM、MTU、`isIncoming` |
| 「PSM 0x13 已打开」+ 吞吐量 ≥ 30 KB/s | **方向 C 可行**，下一步是实现草案（findings §5） |
| 「PSM 0x13 已打开」+ 吞吐量 ≈ 5 KB/s | 通道不是瓶颈（H-S 成立），回到第 2 步的结论 |
| 手柄在程序运行期间断开蓝牙 | 额外通道把 HID 连接弄断了——按 PS 键重新连接；记录发生在哪一步 |

## 第 5 步：系统里有没有可调的开关（只读，10 分钟）

```
strings -a /usr/sbin/bluetoothd | grep -i -E 'sniff|linkpolicy|packettype|flushtimeout' | sort -u | head -50
defaults read com.apple.Bluetooth 2>/dev/null | head -80
sudo defaults read /Library/Preferences/com.apple.Bluetooth 2>/dev/null | head -80
log stream --predicate 'process == "bluetoothd"' --info --style compact | grep -i -E 'sniff|mode|interval|packet' 
```

最后一条在运行测速程序和重连手柄时观察，`Ctrl-C` 结束。

- 找到看起来像开关的键名（例如包含 `Sniff`）→ **先只读、记录**，不要直接 `defaults write`；把键名贴回来，我们再决定怎么安全试验（⚠️ 写入前先 `defaults export` 备份，恢复时 `defaults delete` 或 `defaults import`）。
- 另可在 Bluetooth Explorer 里打开手柄的连接信息窗口，看有没有「链路模式 / Sniff」之类的字段（我不确定这个字段是否存在 [待核实]）。
- 日志里出现 `Exit Sniff` / `ForceActive` 之类字样 → 记下，说明系统内部有对应的状态机。

## 第 6 步：Linux 参照（可选）

如果你有 Linux 机器 + DualSense：`btmon` 抓一次连接，看 Linux 链路是否处于 sniff（`Mode Change` 事件）、ACL 分片大小、HIDP 头。这能回答「为什么 Linux 不受限」（findings §6 第 5 条），并给 macOS 提供可对照的参数。

## 第 7 步：扬声器包格式 / 省流实验（需要 libopus，20 分钟）

先确认基线（Linux 的参数）：
```
./speaker-probe --report 35 --frame-ms 10 --bitrate 160000
```
听手柄扬声器：
- **完全没声音** → 本程序的格式与手柄期望不一致（比如 `state63` 子包缺失）。贴回现象，我们再对照 mdrv 的字节逐项排查；如果你有 Linux 环境，可以先在 Linux 上改 mdrv 的参数确认手柄接受什么。
- **有断续的 440Hz** → 格式正确，继续省流矩阵（每组跑 3 秒，记录有声 / 无声 / 变调）：

| 命令 | 目的 |
|---|---|
| `--report 35 --frame-ms 10 --bitrate 80000`（100 字节） | 手柄是否接受更小的 10ms 帧 |
| `--report 35 --frame-ms 10 --bitrate 32000`（40 字节） | 同上，更小 |
| `--report 33 --frame-ms 20 --bitrate 64000` | 是否接受 20ms 帧 |
| `--report 33 --frame-ms 40 --bitrate 24000` | 是否接受 40ms 帧（0x33 报告） |
| `--report 33 --frame-ms 60 --bitrate 24000` | 是否接受 60ms 帧（findings 推荐的省流组合） |
| `--report 32 --frame-ms 60 --bitrate 16000` | 是否接受最小的 0x32 报告 |

注意：`IOHIDDeviceSetReport` 的速率不够，所以声音一定是**断续**的；这里测的是「格式是否被接受」。如果 60ms 帧的组合有声，并且程序打印的「音频占比」接近 100%，说明省流方案在带宽上可行。

## 第 8 步：硬件旁路（可选，需要硬件）

买一块 Raspberry Pi **Pico 2 W**（不是旧的 Pico W，后者没有扬声器），按 [loteran/DS5Dongle](https://github.com/loteran/DS5Dongle) 的说明刷固件（macOS 构建脚本 `tools/build-macos.sh`）。把手柄配对到 Pico，插到 Mac：
1. 系统信息 → USB：是否出现 DualSense（054C:0CE6）和一个 USB 音频设备？
2. 用本项目 App 的 USB 路径：HID 报告、HD 震动、扬声器同步能否工作？
3. 记录延迟（App 里的估算值 + 听感）。

## 结果汇总模板

```
macOS 版本 / 芯片：
第 1 步：输入报告 __/秒；输出 0x31 中位数 __ms；GetReport 0x20 中位数 __ms；Wi-Fi 关闭后吞吐 __
第 2 步：Sniff（是/否，间隔 __ 时隙）；ACL 片段大小 __；HIDP 头 __；通道 __
第 3 步：CoreHaptics 期间报告 ID __，大小 __，速率 __；音频事件 __
第 4 步：PSM 0x13：__（错误码 / 成功，吞吐 __ KB/s）
第 5 步：发现的键 / 日志 __
第 7 步：基线有声？__；省流矩阵 __
```
