# 多手柄支持 · 设计文档

> 状态：待实现。本文档写给接手实现的开发者 / agent，目标是在不破坏现有单手柄行为的前提下，让多个手柄同时工作、分别设置。
> 阅读顺序：先读 README 的「设计思路」，再读本文。代码在 `Sources/ControllerMusicVisualizer/`。

## 1. 目标

- 同时连接多个手柄（例如 DualSense + 8BitDo），**一起震动**。
- 每个手柄**分别设置**：跟随音乐 / 按摩、模式、预设、强度等。例如 DualSense 跟随音乐「低音」，8BitDo 同时做「捶背」按摩。
- 系统声音采集和音乐分析**只做一份**，所有手柄共用。
- 只连一个手柄时，界面和行为与现在基本一致。

## 2. 已确定的产品决策

| # | 决策 |
|---|---|
| D1 | 顶部用**手柄下拉框**选择要编辑的手柄（不用页签）。每项显示：名称 · 连接方式 · 电量，例如「DualSense · USB · 95%」 |
| D2 | 下拉框选中哪个手柄，下方显示的就是**该手柄自己的设置** |
| D3 | 右上角「开始 / 停止」是**全局**的，一键控制所有已启用的手柄 |
| D4 | 每个手柄有「**启用**」勾选；未启用的手柄 App 完全不碰（等同于三项都交给游戏） |
| D5 | **新手柄连上：自动加入，复制当前选中手柄的设置**；手柄断开：**记住它的设置**，下次连上（同一手柄）自动恢复 |
| D6 | 底部 L/R 电平条**只显示当前选中的手柄** |
| D7 | 每个手柄的 L2/R2 **只调它自己的强度** |
| D8 | 按手柄能力**隐藏不支持的设置项**：没有灯条 → 隐藏灯光设置；没有自适应扳机 → 隐藏阻尼（但仍可保留「L2/R2 调强度」）；不是 USB DualSense → 隐藏 HD 开关 |

## 3. 每个手柄的设置 vs 全局设置

**每个手柄（`ControllerSettings`，可 Codable 持久化）**

| 字段 | 现在在哪里 | 备注 |
|---|---|---|
| `enabled` | 新增 | D4 |
| `source`（音乐 / 按摩） | `HapticsController.source` | |
| `musicMode`、`sensitivity`、`responsiveness` | `HapticsController` → `MusicAnalyzer` | 见 §5 分析器改造 |
| `preset`、`speed` | `HapticsController` | 每个会话有自己的 `massageTime` |
| `intensity` | `HapticsController` | 0...3 |
| `vibrationEnabled`、`hdEnabled` | `HapticsController` | |
| `triggersEnabled`、`triggerResistance` | `HapticsController` | |
| `lightEffects`、`lightSpeed`、`lightRange` | `HapticsController` / `MusicAnalyzer.lightSpeed` | 灯条平滑要从分析器移到会话里，见 §5 |

**全局**：`running`（开始 / 停止）、界面语言、当前选中的手柄 ID。

## 4. 架构

```
SystemAudioTap ─► MusicAnalyzer（共享，一份）─► MusicFrame（三种模式的震动 + 灯光原始特征）
                        │
                        └─► HapticWaveform（共享，HD 音乐波形）

ControllerRegistry ─ 发现 / 插拔 / 身份识别 ─┬─ ControllerSession A（DualSense, USB）── DualSenseHID + HDHapticOutput
                                            ├─ ControllerSession B（8BitDo）──────── RumbleHapticOutput (CoreHaptics)
                                            └─ …

AppModel（原 HapticsController 的全局部分）：running、选中的会话、100Hz 主循环 → 依次调用每个会话的 tick(frame)
```

### 4.1 新类型

| 类型 | 职责 |
|---|---|
| `ControllerIdentity` | 手柄的稳定身份：用于持久化设置和把 GameController / HID / 音频设备对上号（§6） |
| `ControllerSettings` | §3 的每手柄设置，`Codable`，存 UserDefaults，键 = `ControllerIdentity.key` |
| `ControllerSession` | 一个手柄的运行时：持有设置、输出通道（`DualSenseHID` / `HDHapticOutput` / `RumbleHapticOutput` / `ControllerFeatures`）、按摩时间、灯条平滑与锁色状态、L/R 电平；提供 `start()`、`stop()`、`tick(frame:dt:)` |
| `ControllerRegistry` | 监听 `GCControllerDidConnect/Disconnect` 和音频设备变化，维护会话列表，处理 D5 |
| `AppModel`（由 `HapticsController` 拆出） | 全局 `running`、主循环 Timer、系统声音采集的启停（任一启用会话为音乐模式或开着灯光时才采集）、权限提示与错误信息 |

### 4.2 从 `HapticsController` 迁移

`HapticsController.swift` 现在把「全局」和「单个手柄」混在一起。建议拆分：

- **移到 `ControllerSession`**：`output`、`hid`、`hd`、`features`、`massageTime`、`meter`、`tick()` 里与单手柄相关的全部逻辑（扳机、震动、`hdFrequency`、`updateLight`、`playerLEDMask`）、`start()` 里选择输出通道的部分、`stop()` 里的清理。
- **留在 `AppModel`**：`running`、`timer`、`tap` / `startTap()`、`analyzer`、`waveform`、`errorMessage` / `notice`、设备变化监听（交给 `ControllerRegistry`）、电量刷新（改为每个会话各自刷新）。
- `devicesChanged()` 现在的「连接方式变化才重启」逻辑要改成**按会话**处理：只重启连接方式变化的那个会话。⚠️ 保留原注释里的约束：App 自己创建 / 销毁聚合设备也会触发设备变化通知，不能因此全部重启，否则会死循环卡死主线程。

## 5. 分析器改造（`MusicAnalyzer.swift`）

现在分析器只算「当前模式」的震动，并且灯条的速度平滑和锁色也在分析器里。多手柄时不同手柄可能用不同模式和灯光参数，所以：

1. **震动**：每块音频同时算出三种模式的结果，`MusicFrame.vibration` 改为 `[MusicMode: (Float, Float)]`（或三个字段）。三种模式共用滤波结果，额外开销很小。`responsiveness` 和 `sensitivity` 目前是分析器的全局参数——两种做法：
   - (a) **推荐**：分析器输出**未平滑**的原始量（相对强度、低音、鼓点脉冲），每个会话按自己的 `responsiveness` 做平滑、按自己的 `sensitivity` 做鼓点判定。需要把 `follow()` 和鼓点检测的状态挪到会话里。
   - (b) 简化：`responsiveness` / `sensitivity` 改为全局设置（所有手柄共用）。界面上要说明。
2. **灯光**：分析器只输出原始特征（`light` 低音对比度、`colorOut` 三频段颜色、`meter`），`followBar`、锁色（`lit` / `latched` / 波谷换色）、`lightRange` 映射移到会话里，每个手柄独立。
3. `HapticWaveform`（HD 音乐波形）保持共享：它与模式无关，多个 USB DualSense 可以读同一个缓冲（每个 `HDHapticOutput` 有自己的读位置，现在已是如此）。

> 注意实时线程：分析器在音频线程运行，会话在主线程读取 `MusicFrame`（现在通过 `OSAllocatedUnfairLock`）。保持这个边界，不要让会话状态被音频线程访问。

## 6. 设备身份与对应关系（关键难点）

一个手柄在系统里会出现为三种东西，需要把它们对上：

| 视图 | 用途 | 现在怎么拿 |
|---|---|---|
| `GCController` | 读扳机按压、电量；非 DualSense 的震动（CoreHaptics）；灯条/扳机后备方案 | `GCController.controllers()` |
| `IOHIDDevice` | DualSense 的直连输出报告（震动 / 扳机 / 灯光 / HD 开关） | `DualSenseHID.open()` 取**第一个**匹配的设备 |
| Core Audio 设备 | USB DualSense 的 HD 震动（第 3/4 声道） | `CA.dualSenseOutputDevice()` 取**第一个**名字含 DualSense 的设备 |

单手柄时「取第一个」没问题；**同时连两个 DualSense 时必须精确对应**。建议：

1. **`DualSenseHID` 改为接收指定的 `IOHIDDevice`**，新增 `static func enumerate() -> [IOHIDDevice]`。身份：**USB 用 `kIOHIDLocationIDKey`**（实测 USB 下没有序列号）；蓝牙优先用 `kIOHIDSerialNumberKey`（通常是 MAC 地址，⚠️ 蓝牙下未实测），没有则用 LocationID。
2. **扳机读数改为直接解析 DualSense 的 HID 输入报告**（USB 报告 0x01：L2 在字节 5、R2 在字节 6；蓝牙报告 0x31：整体后移 1 字节——以 Linux `hid-playstation` 为准核对），这样 DualSense 会话完全不依赖 `GCController`，就绕开了「哪个 GCController 对应哪个 HID 设备」的问题。电量也可从输入报告解析（状态字节低 4 位 × 10%）。
3. **HD 音频设备**：✅ 已实测，音频设备 UID 包含 HID 的 LocationID（十六进制、不带 `0x`），结尾 `:1` 是输出设备、`:2` 是输入（手柄麦克风）：

   ```
   HID   DualSense Wireless Controller | USB | LocationID 0x1120000 | Serial（无）
   Audio 146 UID  AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Wireless Controller:1120000:1   ← 输出，HD 用这个
   Audio 151 UID  AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Wireless Controller:1120000:2   ← 输入
   ```

   匹配规则：`uid.hasSuffix(":\(String(locationID, radix: 16)):1")`，且输出声道数 ≥ 4。现在的 `CA.dualSenseOutputDevice()` 只按名字取第一个，两个 DualSense 时会选错。
4. **非 DualSense 手柄**（8BitDo、DualShock 4、Xbox）：只用 `GCController`。身份用 `vendorName` + `productCategory` + 在同类中的序号；持久化时同名同类手柄可能互换设置，可接受。
5. GameController 中的 DualSense 对象要**排除在非 DualSense 列表之外**（`extendedGamepad is GCDualSenseGamepad`），避免同一手柄出现两个会话。

### 6.1 实测：同时连接 DualSense + 8BitDo Lite 2（S 模式）

```
HID: DualSense Wireless Controller | Sony Interactive Entertainment | VID 0x54c PID 0xce6 | USB
HID: Pro Controller | Nintendo.Co.Ltd. | VID 0x57e PID 0x2009 | USB          ← 8BitDo 在 S 模式下伪装成 Switch Pro
GC:  Pro Controller | 类别 Switch Pro Controller | 震动 ✓（Left/Right Handle 分开）| 灯条 ✗ | 电量 30%
GC:  DualSense Wireless Controller | 类别 DualSense | 震动 ✓ | 灯条 ✓ | 电量 95%
```

- 8BitDo 在其他模式下被识别为普通 HID 手柄（VID 0x2dc8 PID 0x5112），`GCController.haptics == nil`，往它的输出报告 1 写数据也不震——这种情况下会话应显示「此模式不支持震动，请切到 S 模式」。
- 8BitDo 的震动锐度用 0.25（已在 `RumbleHapticOutput` 实现）。

## 7. 界面

```
┌───────────────────────────────────────────────┐
│ [DualSense · USB · 95%        ▾]  中|EN  [▶ 开始] │  ← 下拉框列出所有手柄；未启用的显示为灰色
│ ☑ 启用这个手柄          HD 震动（USB）运行中     │  ← 该手柄的启用开关和引擎状态
├───────────────────────────────────────────────┤
│ [ 跟随音乐 | 按摩 ]                              │
│ …（与现在相同，绑定到选中会话的设置）…              │
│ App 控制震动 / 扳机 / 灯光（按能力隐藏）            │
├───────────────────────────────────────────────┤
│ L ▮▮▮▯▯   R ▮▮▯▯▯（选中手柄）                     │
└───────────────────────────────────────────────┘
```

- 只有一个手柄时下拉框只有一项，可以直接显示为文字（不出现下拉箭头），保持现在的样子。
- 下拉框每项右侧可加一个小圆点表示该手柄当前是否在震动（可选）。
- `ContentView` 现在通过 `@EnvironmentObject var h: HapticsController` 绑定设置，改为绑定 `model.selectedSession`（`ControllerSession` 设为 `ObservableObject`，或把设置做成 `@Published var settings: ControllerSettings` 并用 `Binding` 投影）。

## 8. 边界情况

| 情况 | 处理 |
|---|---|
| 运行中插入新手柄 | 自动建会话（D5 复制当前选中手柄的设置；若有记忆则用记忆），`running` 时立即启动该会话 |
| 运行中拔掉手柄 | 停止并移除会话（保存设置）；若它是选中的，选中切到第一个 |
| USB ↔ 蓝牙切换（同一手柄） | 身份相同 → 只重启该会话（HD 只在 USB 可用） |
| 所有手柄都未启用 | 「开始」置灰，提示「没有启用的手柄」 |
| 系统声音采集 | 只要有一个启用的会话需要（音乐模式，或开着灯光）就采集；全部是按摩且关灯光时不采集 |
| 两个会话共用一个物理手柄 | 必须避免（§6 第 5 条） |

## 9. 建议的实现顺序

1. 提取 `ControllerSettings` + `ControllerSession`，**仍然只支持一个手柄**，行为与现在完全一致（回归测试）。
2. 分析器改造（§5），单手柄回归测试。
3. `ControllerRegistry` + 多会话 + 主循环遍历会话；先支持「DualSense + 非 DualSense」各一个（无需 §6 的精确对应）。
4. 界面下拉框、按能力隐藏、启用开关、持久化（D5）。
5. 两个 DualSense 同时连接：§6 的精确对应（HID 设备、输入报告读扳机、HD 音频设备）。

## 10. 云端开发、本地测试的分工

实现者在云主机上，**拿不到手柄，且如果云主机是 Linux，本项目根本无法编译**（GameController、CoreAudio、IOKit 都是 macOS 专用框架）。建议：

1. **加 macOS 编译检查（GitHub Actions）**：`.github/workflows/build.yml`，`runs-on: macos-latest`，执行 `swift build -c release` 和 `swift test`。每次推送都能确认能编译、单元测试通过。
2. **把纯逻辑写成可测试的单元**（新增 `Tests/` 目标，`swift test` 在 macOS 编译机上即可运行，无需手柄）：
   - `ControllerSettings` 的编码 / 解码、按身份保存与恢复、D5 的「复制当前设置」
   - `ControllerIdentity` 的生成，以及「HID LocationID ↔ 音频设备 UID」匹配（用 §6 的实测字符串做测试数据）
   - `DualSenseHID` 的报告构造：把 `send()` 里拼字节的部分抽成纯函数 `makeReport(state) -> [UInt8]`，测试各标志位（HD、交给游戏、交出时的默认值）和蓝牙 CRC
   - DualSense 输入报告解析（扳机、电量），用录制好的报告字节做测试数据
   - `MusicAnalyzer`：喂合成音频（正弦、底鼓、静音），检查三种模式的输出范围、相对强度、鼓点检测
   - `MassagePreset`：强度范围、随机轮播不重复、长时间运行开销
3. **需要实物的测试**交给本机：实现者完成后，在 PR 里列出 §11 中需要实物确认的条目，由仓库作者在本机 `./build.sh` 后逐条测试并反馈。
4. **调试参数**：保留 `--autostart`、`--massage`，可按需增加（例如 `--select <序号>` 打开时选中某个手柄），方便本机快速复现。

## 11. 测试清单

- [ ] 单个 DualSense（USB / 蓝牙）：所有现有功能与改造前一致（音乐三模式、按摩 14 种、HD、扳机、灯光、交给游戏、电量）
- [ ] DualSense + 8BitDo（S 模式）：两者同时震动；分别设置不同模式；L2/R2 只影响各自强度
- [ ] 8BitDo 选中时不显示灯光 / 阻尼 / HD 设置
- [ ] 运行中插拔任一手柄，另一个不中断
- [ ] 拔掉再插上同一手柄，设置恢复
- [ ] 新手柄首次连接，复制当前选中手柄的设置
- [ ] 两个 USB DualSense：HD 各自驱动正确的手柄（左右不串）
- [ ] 后台运行（App 不在前台）时扳机阻尼和灯光依然有效
- [ ] 停止后所有手柄恢复默认（扳机关、灯条默认蓝、兼容震动）

## 12. 现有代码中的经验与陷阱（务必保留）

- **聚合设备变化会触发设备列表通知**：只在手柄连接方式真的变化时重启，否则死循环卡死。
- **系统录音权限弹窗会阻塞 Core Audio 调用**：采集必须在后台线程启动（`startTap()`）。
- **`CHHapticAdvancedPatternPlayer` 在手柄上不可用**（报 4097）：只能用普通 player + `sendParameters`。
- **HID 报告的震动标志位兼有模式切换作用**：bit0/bit1 都清零 = HD 模式；交给游戏时只置 bit1。
- **交出控制权时先发一次默认值**，否则手柄保留旧设置。
- **在属性观察器里不要用 `inout` 传自身属性再调用会修改它的方法**（Swift 独占访问冲突，曾导致闪退）。
- HD 载波频率不低于 50Hz（实测 50–65Hz 最强）；DualSense 兼容震动锐度 1，其他手柄 0.25。
