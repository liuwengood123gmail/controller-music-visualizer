package app.cmv.engine.android

import android.content.Context
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import android.view.InputDevice
import app.cmv.engine.Battery
import app.cmv.engine.Bilingual
import app.cmv.engine.Capabilities
import app.cmv.engine.ControllerInfo
import app.cmv.engine.ControllerSettings
import app.cmv.engine.DeviceAccess
import app.cmv.engine.LatencyBreakdown
import app.cmv.engine.LinkKind
import app.cmv.engine.MassagePreset
import app.cmv.engine.SessionStatus
import app.cmv.engine.Source
import java.util.UUID

/**
 * 一个手柄的运行时（Android 底层），对应 macOS 的 ControllerSession。每 10ms 的计算在 Swift 的 SessionEngine 里，
 * 这里只负责选输出通道、把计算结果发给设备。所有方法都在引擎线程上调用。
 *
 * 输出通道（docs/cross-platform-design.md §7.2，按优先级）：
 * - DualSense：B 档 Android 17 HID（不抢占系统）> USB 直连（抢占 HID 接口）> A 档系统震动 / 灯光；
 *   USB 时另开 4 声道音频做 HD 震动 + 扬声器（C 档）。
 * - 其他手柄：A 档。
 */
class Session(
    private val context: Context,
    var found: Found,
    settings: ControllerSettings,
    private val core: Long,
    private val captureLatencyMs: () -> Double?,
) {
    val id: String = UUID.randomUUID().toString()
    val identity get() = found.identity
    var settings: ControllerSettings = settings; private set

    private val native = NativeCore.sessionCreate().also { NativeCore.sessionSetSettings(it, settings.toJson()) }
    private val usbManager = context.getSystemService(UsbManager::class.java)

    var isActive = false; private set
    var armed = false; private set
    private var engineName = Bilingual.DASH
    private var error: Bilingual? = null
    private var battery: Battery? = null
    var level = floatArrayOf(0f, 0f); private set
    private var randomNow: MassagePreset? = null
    private var latency: LatencyBreakdown? = null
    private var audioStats: String? = null

    // 输出通道
    private var system: SystemOutput? = null
    private var link: DualSenseLink? = null
    private var ds = 0L
    private var audio: ControllerAudio? = null
    private var hdActive = false
    private var alignDelayMs = 0.0
    private val out = FloatArray(NativeCore.TICK_COUNT)
    private val report = ByteArray(128)

    /** Android 17 的 HID 链接（异步打开好之后由引擎交进来） */
    var hid17: DualSenseLink? = null

    /** 系统输入设备上的扳机轴（App 在前台时由 Activity 转发） */
    var axisTriggers = floatArrayOf(0f, 0f)

    var rumbleUpdateMs = 40

    // MARK: 能力（D8）

    val isDualSense get() = identity.isDualSense
    private val inputDevice: InputDevice? get() = found.inputDeviceId?.let { InputDevice.getDevice(it) }
    private val usbPermitted get() = found.usb?.let { usbManager.hasPermission(it) } == true
    /** 能直接发 DualSense 报告（B 档或 USB 直连） */
    private val hidAvailable get() = isDualSense && (hid17 != null || usbPermitted)
    private val systemVibrators get() = Build.VERSION.SDK_INT >= 31 && (inputDevice?.vibratorManager?.vibratorIds?.isNotEmpty() == true)
    private val systemLights get() = Build.VERSION.SDK_INT >= 31 && (inputDevice?.lightsManager?.lights?.isNotEmpty() == true)

    /** 能力和授权提示会查系统服务（binder 调用），所以缓存起来：连接变化、授权变化、每 5 秒刷新一次 */
    var capabilities: Capabilities = computeCapabilities(); private set
    private var access: DeviceAccess? = computeAccess()

    fun refreshCapabilities() {
        capabilities = computeCapabilities()
        access = computeAccess()
    }

    private fun computeCapabilities() = Capabilities(
            isDualSense = isDualSense,
            hasLight = hidAvailable || systemLights,
            hasAdaptiveTriggers = hidAvailable,
            hasHD = isDualSense && found.usb != null,
            hasSpeaker = isDualSense && found.usb != null && hidAvailable,
            canVibrate = hidAvailable || systemVibrators || (isDualSense && found.usb != null),
        )

    private fun computeAccess(): DeviceAccess? = when {
            !isDualSense || hidAvailable -> null
            Hid17.supported && !Hid17.granted(context) -> DeviceAccess(
                Bilingual("授予「HID 设备访问」权限：启用扳机阻尼、精确灯光和后台 L2/R2" + if (found.usb != null) "、手柄扬声器" else "",
                          "Grant HID device access: enables trigger resistance, exact lights, background L2/R2" + if (found.usb != null) " and the speaker" else ""),
                Hid17.PERMISSION)
            found.usb != null -> DeviceAccess(
                Bilingual("授权 USB 直连：启用扳机阻尼、精确灯光、后台 L2/R2 和手柄扬声器。直连期间系统收不到这个手柄的按键，停止后要重新插拔一次",
                          "Allow USB direct control: enables trigger resistance, exact lights, background L2/R2 and the speaker. The system won't see this controller's buttons meanwhile; replug it after stopping"),
                null)
            else -> null
        }

    // 实际生效的开关 = 用户勾选 且 手柄支持
    private val effVibration get() = settings.vibrationEnabled && capabilities.canVibrate
    private val effTriggers get() = settings.triggersEnabled
    private val effLights get() = settings.lightEffects && capabilities.hasLight
    private val effSpeaker get() = settings.speakerEnabled && capabilities.hasSpeaker
    val allLeftToGame get() = !effVibration && !effTriggers && !effLights && !effSpeaker

    /** 需要系统声音：扬声器同步播放，或跟随音乐且震动 / 灯光由 App 控制 */
    val needsAudio get() = armed && settings.enabled && !allLeftToGame &&
        (effSpeaker || (settings.source == Source.MUSIC && (effVibration || effLights)))

    fun info(): ControllerInfo = ControllerInfo(
        id = id, name = found.name,
        link = if (isDualSense) (if (found.bluetooth) LinkKind.BLUETOOTH else LinkKind.USB) else null,
        battery = battery, capabilities = capabilities, settings = settings,
        status = SessionStatus(isActive, engineName, error),
        latency = latency, audioStats = audioStats, randomNow = randomNow, access = access,
    )

    fun refreshBattery() {
        if (!isActive) refreshCapabilities()
        val fromHid = (link ?: hid17)?.freshInput()
        battery = when {
            fromHid != null -> Battery(fromHid[2].toInt(), fromHid[3] > 0.5f)
            else -> inputDevice?.let { SystemOutput.battery(it) }
        }
    }

    // MARK: 设置变化

    /** 返回 true 表示快照里的东西变了 */
    fun apply(new: ControllerSettings) {
        val old = settings
        if (new == old) return
        settings = new
        NativeCore.sessionSetSettings(native, new.toJson())
        if (isActive) {
            if (new.triggersEnabled != old.triggersEnabled || new.lightEffects != old.lightEffects) applyControls()
            if (new.lightEffects != old.lightEffects && !new.lightEffects) system?.releaseLights()
            if (new.speakerVolume != old.speakerVolume) applySpeaker()
        }
        val restart = new.source != old.source || new.vibrationEnabled != old.vibrationEnabled ||
            new.hdEnabled != old.hdEnabled || new.speakerEnabled != old.speakerEnabled
        val startStop = new.enabled != old.enabled || new.allLeftToGame != old.allLeftToGame
        if (restart || startStop) reconcile(restart && new.enabled == old.enabled)
    }

    // MARK: 开始 / 停止

    fun arm() { armed = true; reconcile(false) }
    fun disarm() { armed = false; shutdown() }
    fun retire() { armed = false; shutdown(); hid17?.close(); hid17 = null; NativeCore.sessionDestroy(native) }

    /** 能力变了（授权、USB 直连、Android 17 HID 打开）：重启输出 */
    fun capabilitiesChanged() { refreshCapabilities(); reconcile(true) }

    /** 连接方式变了（USB ↔ 蓝牙，或系统输入设备换了编号） */
    fun update(newFound: Found) {
        val changed = newFound.usb?.deviceName != found.usb?.deviceName || newFound.bluetooth != found.bluetooth ||
            (newFound.inputDeviceId != found.inputDeviceId && link == null)
        found = newFound
        if (changed) { refreshCapabilities(); reconcile(true) }
    }

    private fun reconcile(restart: Boolean) {
        val want = armed && settings.enabled && !allLeftToGame
        if (want) {
            if (isActive) { if (restart) { shutdown(); startOutputs() } } else startOutputs()
        } else if (isActive) shutdown()
    }

    private fun startOutputs() {
        error = null
        NativeCore.sessionReset(native)
        val usb = found.usb
        // 1) 直接发 DualSense 报告：Android 17 HID 优先，否则 USB 直连
        if (isDualSense) {
            link = hid17 ?: if (usb != null && usbPermitted) UsbDirectLink.open(usbManager, usb) else null
            link?.let { l ->
                ds = NativeCore.dsCreate(l.bluetooth)
                applyControls()
                NativeCore.dsSend(ds)
                flushReports()
            }
        }
        // 2) USB DualSense：4 声道音频（HD 震动 + 扬声器）
        val wantHD = effVibration && settings.hdEnabled && isDualSense && usb != null
        val wantSpeaker = effSpeaker
        if (wantHD || wantSpeaker) {
            // 先走系统音频（AAudio）；系统没把手柄登记成输出时，在 USB 直连上直接输出
            val reasons = mutableListOf<String>()
            audio = ControllerAudio.open(context, core, wantHD) { reasons += it }
                ?: (link as? UsbDirectLink)?.let { l -> ControllerAudio.openUsb(core, wantHD, l) { reasons += it } }
            if (audio == null) {
                val why = reasons.joinToString("; ")
                Log.w("cv-engine", "controller audio unavailable: $why")
                if (wantSpeaker || link == null) error = Bilingual(
                    "无法以 4 声道打开手柄的 USB 音频（$why），HD 震动 / 扬声器不可用。",
                    "Could not open the controller's USB audio with 4 channels ($why); HD haptics / speaker are unavailable.")
            }
            if (audio != null) {
                if (wantHD) { hdActive = true; if (ds != 0L) NativeCore.dsSetHd(ds, true) }
                if (wantSpeaker) applySpeaker()
            }
        }
        // 3) 系统震动 / 灯光（没有直接 HID 时）。HD 运行时不用系统震动，避免内核驱动把手柄切回兼容模式
        if (link == null && Build.VERSION.SDK_INT >= 31) {
            inputDevice?.let { d -> system = SystemOutput(d, rumbleUpdateMs) }
        }
        if (settings.vibrationEnabled && !capabilities.canVibrate) {
            error = Bilingual("这个手柄不支持震动。8BitDo 请切到 S 模式（Switch 模式）后重新连接。",
                              "This controller can't vibrate. For 8BitDo, switch to S (Switch) mode and reconnect.")
        }
        val base = when {
            !settings.vibrationEnabled -> Bilingual("震动交给游戏", "Vibration left to games")
            hdActive -> if (link != null) Bilingual("HD 震动（USB）", "HD haptics (USB)")
                        else Bilingual("HD 震动（USB，实验）", "HD haptics (USB, experimental)")
            link != null -> link!!.description
            system?.canVibrate == true -> Bilingual("系统震动（兼容）", "System vibration (compat)")
            else -> Bilingual("震动不可用", "Vibration unavailable")
        }
        engineName = if (audio != null && effSpeaker) Bilingual(base.zh + " + 手柄扬声器", base.en + " + speaker") else base
        updateAlignment()
        refreshLatency()
        Log.i("cv-engine", "session ${identity.key}: ${engineName.en}")
        isActive = true
    }

    private fun shutdown() {
        if (!isActive) return
        audio?.stop(); audio = null
        hdActive = false; latency = null; audioStats = null; alignDelayMs = 0.0
        if (ds != 0L) {
            NativeCore.dsSetMotors(ds, 0f, 0f)
            NativeCore.dsStop(ds)
            flushReports()
            NativeCore.dsDestroy(ds); ds = 0L
        }
        // Android 17 的 HID 链接保留（下次开始直接用）；USB 直连关掉，释放接口
        if (link != null && link !== hid17) link?.close()
        link = null
        system?.stop(); system = null
        isActive = false
        engineName = Bilingual.DASH
        level = floatArrayOf(0f, 0f)
        randomNow = null
    }

    private fun applyControls() {
        if (ds == 0L) return
        NativeCore.dsSetControls(ds, effVibration, effTriggers, effLights)
    }

    /** 打开扬声器通路（路径 3 + 硬件音量 / 前置放大，与 macOS 默认一致）并设置软件音量 */
    private fun applySpeaker() {
        val a = audio ?: return
        if (!effSpeaker || ds == 0L) return
        NativeCore.dsSetSpeaker(ds, true, 0x64, 2)
        a.setSpeakerVolume(settings.speakerVolume)
    }

    private fun flushReports() {
        val l = link ?: return
        while (true) {
            val n = NativeCore.dsTakeReport(ds, report)
            if (n <= 0) break
            l.send(report, n)
        }
    }

    // MARK: 每 10ms 一次

    /** 返回 true 表示快照里的东西变了（强度被 L2/R2 改了、随机轮播换了） */
    fun tick(dt: Float, count: Int): Boolean {
        if (!isActive) return false
        if (count % 50 == 0) updateAlignment()
        var flags = 0
        if (effVibration) flags = flags or NativeCore.F_VIBRATION
        if (effTriggers) flags = flags or NativeCore.F_TRIGGERS
        if (effLights) flags = flags or NativeCore.F_LIGHTS
        if (capabilities.hasAdaptiveTriggers) flags = flags or NativeCore.F_ADAPTIVE_TRIGGERS
        if (ds != 0L || system?.hasLight == true) flags = flags or NativeCore.F_PLAYER_LEDS
        if (hdActive && audio != null) flags = flags or NativeCore.F_HD_ACTIVE
        val input = link?.freshInput()
        val tl = input?.get(0) ?: axisTriggers[0]
        val tr = input?.get(1) ?: axisTriggers[1]
        NativeCore.sessionTick(native, core, flags, tl, tr, dt, alignDelayMs, out)

        var changed = false
        val intensity = out[NativeCore.T_INTENSITY]
        if (!intensity.isNaN()) { settings = settings.copy(intensity = intensity); changed = true }
        level = floatArrayOf(out[NativeCore.T_LEVEL_L], out[NativeCore.T_LEVEL_R])
        val rn = out[NativeCore.T_RANDOM_NOW].toInt().takeIf { it >= 0 }?.let { MassagePreset.entries.getOrNull(it) }
        if (rn != randomNow) { randomNow = rn; changed = true }

        val hasLight = out[NativeCore.T_LIGHT] > 0.5f
        val r = out[NativeCore.T_RED]; val g = out[NativeCore.T_GREEN]; val b = out[NativeCore.T_BLUE]
        val leds = out[NativeCore.T_LEDS].toInt().takeIf { it >= 0 }
        if (out[NativeCore.T_HD] > 0.5f) {
            audio?.set(out[NativeCore.T_HD_L], out[NativeCore.T_HD_R], out[NativeCore.T_HD_FREQ], out[NativeCore.T_HD_MUSIC] > 0.5f)
        }
        if (ds != 0L) {
            val res = out[NativeCore.T_RESISTANCE]
            if (!res.isNaN()) NativeCore.dsSetTriggerResistance(ds, res)
            if (hasLight) { NativeCore.dsSetLight(ds, r, g, b); if (leds != null) NativeCore.dsSetPlayerLeds(ds, leds) }
            // 顺便负责定期重发；HD 运行时马达值是 0，曲线不影响
            NativeCore.dsSetMotors(ds, SystemOutput.compatBoost(out[NativeCore.T_MOTOR_L]), SystemOutput.compatBoost(out[NativeCore.T_MOTOR_R]))
            flushReports()
        } else system?.let { s ->
            if (!hdActive && effVibration) s.setMotors(out[NativeCore.T_MOTOR_L], out[NativeCore.T_MOTOR_R])
            if (hasLight) s.setLights(r, g, b, leds)
        }
        audio?.let { if (it.disconnected) { error = Bilingual("手柄音频断开了。", "Controller audio disconnected."); changed = true } }
        return changed
    }

    /** 震动相对扬声器 / HD 载波的对齐延迟（规则在 Swift 里，同 macOS） */
    private fun updateAlignment() {
        val a = audio
        alignDelayMs = if (a == null || settings.source != Source.MUSIC) 0.0
        else NativeCore.alignDelayMs(hdActive, effSpeaker, a.marginMs(), a.outputMs, Double.NaN)
    }

    /** 延迟分解和调试信息（每 5 秒刷新） */
    fun refreshLatency() {
        val a = audio
        if (a == null || !effSpeaker) { latency = null; audioStats = null; return }
        val margin = a.marginMs()
        latency = LatencyBreakdown(captureMs = captureLatencyMs() ?: 0.0, marginMs = margin, controllerOutputMs = a.outputMs)
        audioStats = "%s · 4 ch · %d Hz · buffer %d · burst %d · margin %.1f ms · underruns %d · xruns %d · align %.0f ms"
            .format(a.backend, a.sampleRate, a.bufferFrames, a.burstFrames, margin, a.underruns(), a.xruns, alignDelayMs)
    }
}
