# Android 版测试说明（P2 界面 + P3 底层，预览版）

> 这一版是**没有在实机上跑过**的「按最大可能做好」版本：代码在云端编译通过，Swift 核心在 Linux 上、JNI 在 CI 的 x86_64 模拟器上测过，
> 但手柄、震动、灯光、USB 音频、屏幕录制授权都需要你在真机上验证。下面按「先易后难」排好了测试顺序，
> 每一步都写了预期结果和出问题时要发给我的东西。

## 安装

1. 打开仓库的 Releases → **android-preview**（每次推送自动更新），手机上下载 `ControllerMusicVisualizer-android.apk`。
   也可以在 Actions 里某次运行的 Artifacts 下载（zip 里是同一个 APK）。
2. 安装时允许「安装未知来源的应用」。要求 **Android 10+、arm64 手机 / 平板**；完整的系统震动 / 灯光要 **Android 12+**。
3. APK 约 30MB（其中 Swift 运行库 + ICU 约占 25MB，以后可以裁剪）。

## 界面里的几个入口

- 右上角 **开始 / 停止**：第一次会申请「录音」和「通知」权限（录音是读取播放声音所必需），然后弹出系统的**屏幕录制**确认框（只用来读声音，不录屏）。
- 右上角 **⋮**：切换**真实引擎 / 假引擎**（5 种剧本：没有手柄、一个 USB DualSense、多手柄、采集被拒绝、运行中拔出）。假引擎不连任何设备，用来先看界面。
- 手柄卡片里的 **「授权」**：USB DualSense 授权「USB 直连」，或 Android 17 授予「HID 设备访问」，解锁扳机阻尼 / 精确灯光 / 扬声器。
- 通知栏常驻通知里有 **停止** 按钮；界面关掉后引擎继续运行。

## 测试顺序

### 0. 界面（假引擎，不需要手柄）
⋮ → 假引擎：多手柄。逐个点：切手柄、改设置、开始（会弹真的屏幕录制框，同意 / 拒绝都试）、电平条在动、拔出剧本 5 秒后 8BitDo 消失、横屏 / 平板变成两栏。
**预期**：不崩溃，所有开关和滑块都能操作，切换语言立即生效。

### 1. A 档：系统震动 / 灯光（Android 12+，任何手柄，USB 或蓝牙）
切回真实引擎，连上 DualSense（先蓝牙）或 8BitDo（S 模式）。不点「授权」。
- 按摩 → 捶背 → 开始：手柄应当按节奏震；DualSense 灯条变色、白灯跟着跳。
- 跟随音乐：开始 → 同意屏幕录制 → 在 Spotify / 网易云 / YouTube Music 等 App 播放音乐。
- **重点观察**：震动是否连贯（系统震动 API 每次调用会重新开始一段效果，默认每 40ms 更新一次，可能有断续感）；延迟大不大。
- 前台时 R2 / L2 调强度（A 档只有 App 在前台时收得到扳机）。

### 2. USB 直连（USB DualSense，任何 Android 版本）
用 USB-C 线连手柄（手机要支持 OTG）。系统可能弹「打开 手柄音乐可视化？」——同意（勾「始终」就不用再授权）。或者在 App 里点「授权」。
- **预期**：引擎名变成「直接控制（USB 直连）」，出现「扳机阻尼」和「手柄扬声器同步播放」选项；扳机变硬、灯光精确、白灯跳动。
- **代价**：直连期间系统收不到这个手柄的按键；停止后**要拔插一次**手柄，系统才会重新接管。

### 3. HD 震动 + 手柄扬声器（USB）
在第 2 步基础上：勾选「HD 震动」「手柄扬声器同步播放」，开始。
- **预期**：引擎名「HD 震动（USB）+ 手柄扬声器」；震动更细腻（跟随音乐时载波就是音乐低频）；手柄扬声器同步出声，延迟小字和调试行有数字。
- 如果出现红字「无法以 4 声道打开手柄的 USB 音频（…）」：这台手机的 USB 音频不支持 4 声道，HD / 扬声器在这台机器上不可用——把红字里括号内的原因发给我。
- 不授权直连时也可以试 HD（「HD 震动（USB，实验）」）：不发 HID 报告，直接往第 3/4 声道写，看会不会震。

### 4. Android 17（API 37.2+）的 HID 访问
手柄卡片会显示「授予『HID 设备访问』权限」，点授权 → 系统权限框 / 设备选择器。
- **预期**：蓝牙和 USB 都变成「直接控制（HID · …）」，扳机阻尼、精确灯光、后台 L2/R2 都能用，而且**不抢占**系统的按键。

### 5. 多手柄、插拔、后台
- 两个手柄同时开（例如 DualSense + 8BitDo），各自设置互不影响；新连上的手柄复制当前选中手柄的设置。
- 运行中拔掉 / 插上；USB ↔ 蓝牙切换后设置还在。
- 锁屏 / 切到别的 App 后继续震（通知栏有常驻通知）。部分厂商省电策略可能会杀后台，需要把 App 加入电池优化白名单。

## 出问题时发给我

1. 截图（尤其红字、引擎名那一行、扬声器下面的调试行）。
2. logcat（电脑上，手机开 USB 调试）：
   ```
   adb logcat -s cv-engine cv-native cv-app AndroidRuntime
   ```
   `cv-native` 里有「controller audio: device …, N ch, …」这一行，能看出手柄音频实际打开成了几个声道；
   `cv-engine` 里有「USB direct: interface …」「session …: <引擎名>」。
3. 手机型号和 Android 版本。

## 不用界面的调试入口（adb）

```
adb shell am start-foreground-service -n app.cmv/app.cmv.engine.android.EngineService --es cmd start
adb shell am start-foreground-service -n app.cmv/app.cmv.engine.android.EngineService --es cmd set --es target 0 --es json '{"source":"按摩","preset":"捶背"}'
adb shell am start-foreground-service -n app.cmv/app.cmv.engine.android.EngineService --es cmd access
adb shell am start-foreground-service -n app.cmv/app.cmv.engine.android.EngineService --es cmd stop
```
每条命令执行后，状态快照打印到 logcat（tag `cv-engine`）。跟随音乐需要屏幕录制授权，只能从界面点「开始」。

## 已知限制

- 只能读到**允许被录制**的 App 的声音（大部分音乐 App 和游戏可以；部分视频 App 禁止）。
- A 档没有扳机阻尼、HD、扬声器（系统 API 不提供），L2/R2 调强度只在 App 前台时有效。
- 蓝牙下的 HD / 扬声器还没做（需要 Android 17 HID 发 0x32 / 0x36 报告，先等第 4 步的结果）。
- 播放采集本身的延迟未知，延迟分解里「采集」一项是按缓冲大小估的。
