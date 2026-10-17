package app.cmv.engine.fake

import app.cmv.engine.Battery
import app.cmv.engine.Bilingual
import app.cmv.engine.Capabilities
import app.cmv.engine.CaptureConsent
import app.cmv.engine.CaptureStatus
import app.cmv.engine.ControllerEngine
import app.cmv.engine.ControllerId
import app.cmv.engine.ControllerInfo
import app.cmv.engine.ControllerSettings
import app.cmv.engine.DeviceAccess
import app.cmv.engine.EngineEvent
import app.cmv.engine.EngineState
import app.cmv.engine.GlobalOptionsPatch
import app.cmv.engine.LatencyBreakdown
import app.cmv.engine.LinkKind
import app.cmv.engine.MassagePreset
import app.cmv.engine.Meter
import app.cmv.engine.SessionStatus
import app.cmv.engine.SettingsPatch
import app.cmv.engine.Source
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 假引擎（与 Swift 版 FakeControllerEngine 对应）。scope 不为空时自己以约 30Hz 推进模拟时间；
 * 为空时由调用方（测试）调用 [advance]。
 */
class FakeControllerEngine(
    private val scenario: Scenario = Scenario.MULTI,
    private val scope: CoroutineScope? = null,
) : ControllerEngine {

    enum class Scenario(val title: Bilingual) {
        /** 没有手柄 */
        NONE(Bilingual("没有手柄", "No controller")),
        /** 一个 USB DualSense（需要授权 USB 直连才有扳机阻尼 / 扬声器） */
        SINGLE_USB(Bilingual("一个 USB DualSense", "One USB DualSense")),
        /** USB DualSense + 蓝牙 DualSense + 8BitDo */
        MULTI(Bilingual("多手柄", "Multiple controllers")),
        /** 用户拒绝屏幕录制授权 */
        CAPTURE_DENIED(Bilingual("采集被拒绝", "Capture denied")),
        /** 多手柄，开始 5 秒后 8BitDo 断开 */
        UNPLUG(Bilingual("运行中拔出", "Unplug while running")),
    }

    private val _state = MutableStateFlow(EngineState())
    private val _meters = MutableStateFlow<Map<ControllerId, Meter>>(emptyMap())
    private val _events = MutableSharedFlow<EngineEvent>(extraBufferCapacity = 16)
    override val state: StateFlow<EngineState> = _state
    override val meters: StateFlow<Map<ControllerId, Meter>> = _meters
    override val events: SharedFlow<EngineEvent> = _events

    private var time = 0.0
    private var runningFor = 0.0
    private var ticker: Job? = null
    private var usbAccessGranted = false

    init {
        val cs = controllers(scenario)
        _state.value = EngineState(controllers = cs, canStart = canStart(cs))
    }

    // MARK: 命令

    @Synchronized override fun start() {
        val s = _state.value
        if (s.running) return
        if (!s.canStart) {
            _state.value = s.copy(error = if (s.controllers.isEmpty()) Bilingual("没有找到手柄", "No controller found")
                                          else Bilingual("没有启用的手柄", "No controller enabled"))
            return
        }
        runningFor = 0.0
        val needsAudio = s.controllers.any { it.settings.enabled && (it.settings.source == Source.MUSIC || it.settings.speakerEnabled) }
        publish(s.copy(running = true, error = null,
                       capture = if (needsAudio) CaptureStatus.NeedsConsent else CaptureStatus.Off))
        scope?.let { sc ->
            ticker = sc.launch {
                while (isActive) { delay(33); advance(0.033) }
            }
        }
    }

    @Synchronized override fun stop() {
        ticker?.cancel(); ticker = null
        publish(_state.value.copy(running = false, capture = CaptureStatus.Off, notice = null))
        _meters.value = emptyMap()
    }

    @Synchronized override fun updateSettings(id: ControllerId, patch: SettingsPatch) {
        val s = _state.value
        publish(s.copy(controllers = s.controllers.map { if (it.id == id) it.copy(settings = patch.apply(it.settings)) else it }))
    }

    override fun focus(id: ControllerId?) {}

    @Synchronized override fun setGlobalOptions(patch: GlobalOptionsPatch) {
        publish(_state.value.copy(options = patch.apply(_state.value.options)))
    }

    @Synchronized override fun provideCaptureConsent(consent: CaptureConsent) {
        val s = _state.value
        if (s.capture != CaptureStatus.NeedsConsent) return
        val granted = consent.granted && scenario != Scenario.CAPTURE_DENIED
        publish(if (granted) s.copy(capture = CaptureStatus.Running, notice = null)
                else s.copy(capture = CaptureStatus.Failed(Bilingual("没有获得屏幕录制授权（假引擎模拟）", "Screen capture was not allowed (simulated)")),
                            error = Bilingual("无法读取系统声音：没有获得授权。跟随音乐不可用，按摩照常。",
                                              "Cannot read system audio: permission denied. Music mode is unavailable; massage still works.")))
    }

    @Synchronized override fun requestDeviceAccess(id: ControllerId) {
        if (id != USB_ID) return
        usbAccessGranted = true
        val s = _state.value
        publish(s.copy(controllers = s.controllers.map { if (it.id == USB_ID) usbDualSense(it.settings) else it }))
    }

    // MARK: 模拟

    /** 推进模拟时间：运行中给出正弦电平 */
    @Synchronized fun advance(dt: Double) {
        time += dt
        val s = _state.value
        if (!s.running) return
        runningFor += dt
        if (scenario == Scenario.UNPLUG && runningFor >= 5 && s.controller(EIGHTBITDO_ID) != null) {
            simulateDisconnect(EIGHTBITDO_ID)
        }
        val m = HashMap<ControllerId, Meter>()
        _state.value.controllers.forEachIndexed { k, c ->
            if (!c.status.isActive) return@forEachIndexed
            if (c.settings.source == Source.MUSIC && s.capture != CaptureStatus.Running) { m[c.id] = Meter.ZERO; return@forEachIndexed }
            val phase = time * 2 * Math.PI * (0.7 + 0.3 * k)
            val i = c.settings.intensity
            m[c.id] = Meter(((0.5 + 0.5 * sin(phase)) * i).toFloat().coerceIn(0f, 1f),
                            ((0.5 + 0.5 * cos(phase * 1.3)) * i).toFloat().coerceIn(0f, 1f))
        }
        _meters.value = m
    }

    @Synchronized fun simulateDisconnect(id: ControllerId) {
        val s = _state.value
        if (s.controller(id) == null) return
        publish(s.copy(controllers = s.controllers.filter { it.id != id }))
        _meters.value = _meters.value - id
        _events.tryEmit(EngineEvent.ControllerDisconnected(id))
    }

    // MARK: 内部

    /** 重算派生字段（运行状态、引擎名、canStart）后发出 */
    private fun publish(s: EngineState) {
        val cs = s.controllers.map { c ->
            val active = s.running && c.settings.enabled && !c.settings.allLeftToGame
            val name = when {
                !active -> Bilingual.DASH
                !c.settings.vibrationEnabled -> Bilingual("震动交给游戏", "Vibration left to games")
                c.capabilities.hasHD && c.settings.hdEnabled -> Bilingual("HD 震动（USB）", "HD haptics (USB)")
                c.access == null && c.capabilities.isDualSense -> Bilingual("直接控制（USB）", "Direct control (USB)")
                else -> Bilingual("系统震动（兼容）", "System vibration (compat)")
            }
            val speaker = active && c.capabilities.hasSpeaker && c.settings.speakerEnabled
            c.copy(
                status = SessionStatus(active, if (speaker) Bilingual(name.zh + " + 手柄扬声器", name.en + " + speaker") else name, null),
                randomNow = if (active && c.settings.source == Source.MASSAGE && c.settings.preset == MassagePreset.RANDOM) MassagePreset.KNEAD else null,
                latency = if (speaker) LatencyBreakdown(captureMs = 20.0, marginMs = 6.8, controllerOutputMs = 8.0) else null,
                audioStats = if (speaker) "4 ch · burst 96 · margin 6.8 ms · underruns 0" else null,
            )
        }
        _state.value = s.copy(controllers = cs, canStart = canStart(cs))
    }

    private fun canStart(cs: List<ControllerInfo>) = cs.any { it.settings.enabled && !it.settings.allLeftToGame }

    private fun usbDualSense(settings: ControllerSettings) = ControllerInfo(
        id = USB_ID, name = "DualSense", link = LinkKind.USB, battery = Battery(95, true),
        capabilities = Capabilities(isDualSense = true, hasLight = true, hasAdaptiveTriggers = usbAccessGranted,
                                    hasHD = true, hasSpeaker = usbAccessGranted, canVibrate = true),
        settings = settings, status = IDLE,
        access = if (usbAccessGranted) null else DeviceAccess(
            Bilingual("授权 USB 直连：启用扳机阻尼、精确灯光和手柄扬声器（直连期间系统收不到这个手柄的按键）",
                      "Allow USB direct control: enables trigger resistance, exact lights and the speaker (the system won't see this controller's buttons meanwhile)"),
            runtimePermission = null),
    )

    private fun controllers(s: Scenario): List<ControllerInfo> {
        val bt = ControllerInfo(
            id = BT_ID, name = "DualSense", link = LinkKind.BLUETOOTH, battery = Battery(40, false),
            capabilities = Capabilities(isDualSense = true, hasLight = true, hasAdaptiveTriggers = false,
                                        hasHD = false, hasSpeaker = false, canVibrate = true),
            settings = ControllerSettings(musicMode = app.cmv.engine.MusicMode.BASS), status = IDLE,
            access = DeviceAccess(Bilingual("授予「HID 设备访问」权限（Android 17+）：启用扳机阻尼和精确灯光",
                                            "Grant HID device access (Android 17+): enables trigger resistance and exact lights"),
                                  runtimePermission = "android.permission.ACCESS_HID"),
        )
        val eightBitDo = ControllerInfo(
            id = EIGHTBITDO_ID, name = "Pro Controller", link = null, battery = Battery(30, false),
            capabilities = Capabilities(isDualSense = false, hasLight = false, hasAdaptiveTriggers = false,
                                        hasHD = false, hasSpeaker = false, canVibrate = true),
            settings = ControllerSettings(source = Source.MASSAGE, preset = MassagePreset.POUND), status = IDLE,
        )
        return when (s) {
            Scenario.NONE -> emptyList()
            Scenario.SINGLE_USB, Scenario.CAPTURE_DENIED -> listOf(usbDualSense(ControllerSettings()))
            Scenario.MULTI, Scenario.UNPLUG -> listOf(usbDualSense(ControllerSettings()), bt, eightBitDo)
        }
    }

    companion object {
        const val USB_ID = "fake-ds-usb"
        const val BT_ID = "fake-ds-bt"
        const val EIGHTBITDO_ID = "fake-8bitdo"
        private val IDLE = SessionStatus(false, Bilingual.DASH, null)
    }
}
