# Android 版（预览）

要求 Android 10+、arm64；系统震动 / 灯光要 Android 12+。已实测：联想拯救者 Y700 二代（TB320FC，Android 15）、红米 Note 13 Pro+（Android 14 / 澎湃 OS 1.0），DualSense USB 和蓝牙。

## 安装

- **下载**：[Releases → android-preview](https://github.com/liuwengood123gmail/controller-music-visualizer/releases/tag/android-preview) 的 `ControllerMusicVisualizer-android.apk`（推到 master 或 Android 分支时自动更新，约 4 分钟出包）。签名固定，新版可以直接覆盖安装。
- **本机编译并装到连着的设备**：`android/scripts/build-local.sh`（首次约 2 分钟，之后改代码约 25 秒）。需要的工具和装法写在脚本开头；签名用 `~/.config/cmv-android-signing` 里的预览版密钥（与 CI 同一把，CI 从仓库 Secrets 读取），没有时退回 debug 签名。
- **小米 / 红米**：开「USB 安装」要插 SIM 卡。不开也行：
  ```bash
  adb push app-release.apk /sdcard/Download/ControllerMusicVisualizer.apk
  adb shell am start -a android.intent.action.VIEW -t application/vnd.android.package-archive -d file:///sdcard/Download/ControllerMusicVisualizer.apk
  ```
  手机上第一次点「允许」（勾「记住我的选择」），之后每次点「安装」。

## 输出方式（按优先级）

| 方式 | 条件 | 能做的 |
|---|---|---|
| **USB 直连** | USB DualSense，插上时同意打开本 App（或卡片里点「授权」） | 扳机阻尼、精确灯光、白灯、后台 L2/R2；**HD 震动和扬声器**走 USB 直接输出（见下）。直连期间系统收不到这个手柄的按键 |
| **Android 17 HID**（未实测） | API 37.2+，授予「HID 设备访问」 | 同上，且不抢占系统按键；蓝牙 HD / 扬声器还没做 |
| **系统接口** | Android 12+，任何手柄（蓝牙 DualSense 就是这一档） | 兼容震动、灯条颜色、玩家灯；没有扳机阻尼 / HD / 扬声器 |

## 实测结论

- **Android 不把 DualSense 当音频输出**：两台设备的 `UsbAlsaManager` 都记为 `hasOutput: false`（内核其实有播放端 `pcmC1D0p`），AAudio 找不到手柄。所以 App 在 USB 直连上自己占用音频流接口（接口 1），用等时传输发 4 声道 16 位 48kHz（每包 1ms，4 × 3ms 排队），`usb_audio.c`。实测扬声器、HD 正常；UAC1 的采样率 / 静音 / 音量请求手柄都拒绝，也不需要。
- **屏幕录制授权**：系统规定每次开始采集都要用户同意。App 停止后保留授权 30 分钟（通知栏「已暂停 / 退出」），手柄全部断开时只保留 1 分钟；期间再开始不弹框，状态栏显示「屏幕共享中」。
- **系统兼容震动偏弱**：一次性 / 每 40ms 重新开始强度一样；真正的原因是灯光更新太频繁（每秒约 20 次）会拖弱同一时刻的震动，所以灯光改为最多每 150ms、颜色变化明显才更新。另外兼容震动（系统接口和 USB 直连）的力度曲线取平方根，中低段更有劲。
- **手柄不操作界面**：App 在前台时丢掉来自手柄的按键、摇杆、触控板事件（防误触），扳机轴照样用来调强度。后台时蓝牙手柄仍能操作系统（全局屏蔽需要无障碍服务，且拦不住摇杆）。
- 插拔、切后台已实测正常；多手柄同时连接还没测。

## 调试

- 日志：`adb logcat -s cv-engine cv-native cv-app AndroidRuntime`。关键行：`session …: <引擎名>`、`USB audio: interface …`、`usb audio: endpoint …`、每秒一行 `rumble stats`（系统接口的震动力度和灯光更新次数）。厂商默认日志缓冲小，可以 `adb logcat -G 16M`。
- 不用界面的入口（只有 adb shell 能调）：
  ```bash
  S="adb shell am start-foreground-service -n app.cmv/app.cmv.engine.android.EngineService --es cmd"
  $S start
  $S stop
  $S access                                                    # 申请 USB 直连 / HID 访问
  $S set --es target 0 --es json '{"source":"按摩","preset":"捶背"}'
  $S rumble --es json '{"amp":255,"ms":2000,"restartMs":40}'   # 系统接口震动对照
  ```
  跟随音乐要屏幕录制授权，只能从界面开始。
- 右上角 ⋮ 可以切到假引擎（5 种剧本），不需要手柄就能看界面。

## 已知限制

- 只能读到允许被录制的 App 的声音（大部分音乐 App 和游戏可以）。
- 蓝牙下没有扳机阻尼、HD、扬声器（Android 16 及以下 App 拿不到蓝牙 HID；Android 17 的路线未实测）。
- APK 约 30MB（Swift 运行库 + ICU），以后可以裁剪。
