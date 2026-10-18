package app.cmv.engine.windows

import app.cmv.engine.Bilingual
import app.cmv.engine.Capabilities
import app.cmv.engine.CaptureConsent
import app.cmv.engine.CaptureStatus
import app.cmv.engine.ControllerEngine
import app.cmv.engine.ControllerId
import app.cmv.engine.ControllerInfo
import app.cmv.engine.ControllerSettings
import app.cmv.engine.EngineEvent
import app.cmv.engine.EngineState
import app.cmv.engine.GlobalOptionsPatch
import app.cmv.engine.Meter
import app.cmv.engine.SessionStatus
import app.cmv.engine.SettingsPatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Windows 真实引擎。W5 阶段只打通「WASAPI 采集 → Swift 分析 → JNI → Kotlin → 界面电平条」：
 * 列出一个代表系统声音的伪手柄，开始后显示它的电平。W6 按 docs/windows-plan.md §2.3 从 Android 引擎复制会话逻辑替换这里。
 *
 * 线程：命令和 10ms 主循环都在单线程执行器里串行执行（与 Android 引擎相同）。
 */
class WindowsControllerEngine : ControllerEngine {
    private val executor = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "cv-engine").apply { isDaemon = true } }
    private val core = NativeCore.coreCreate(200f)

    private val _state = MutableStateFlow(EngineState())
    private val _meters = MutableStateFlow<Map<ControllerId, Meter>>(emptyMap())
    private val _events = MutableSharedFlow<EngineEvent>(extraBufferCapacity = 16)
    override val state: StateFlow<EngineState> = _state
    override val meters: StateFlow<Map<ControllerId, Meter>> = _meters
    override val events: SharedFlow<EngineEvent> = _events

    private var settings = ControllerSettings()
    private var running = false
    private var capture: CaptureStatus = CaptureStatus.Off
    private var session = 0L
    private var captureHandle = 0L
    private var ticker: ScheduledFuture<*>? = null
    private var tickCount = 0L
    private var lastTickNanos = 0L
    private val tickOut = FloatArray(NativeCore.TICK_COUNT)
    private val captureInfo = IntArray(5)

    init { publish() }

    override fun start() = command {
        if (running || !settings.enabled) return@command
        NativeCore.highResTimer(true)
        session = NativeCore.sessionCreate()
        NativeCore.sessionSetSettings(session, settings.toJson())
        captureHandle = NativeCore.captureStart(core)
        capture = CaptureStatus.Starting
        running = true
        lastTickNanos = System.nanoTime()
        ticker = executor.scheduleAtFixedRate({ safely(::tick) }, 0, 10, TimeUnit.MILLISECONDS)
        publish()
    }

    override fun stop() = command {
        if (!running) return@command
        ticker?.cancel(false)
        ticker = null
        NativeCore.captureStop(captureHandle)
        captureHandle = 0
        NativeCore.sessionDestroy(session)
        session = 0
        NativeCore.coreReset(core)
        NativeCore.highResTimer(false)
        running = false
        capture = CaptureStatus.Off
        _meters.value = emptyMap()
        publish()
    }

    override fun updateSettings(id: ControllerId, patch: SettingsPatch) = command {
        if (id != ID) return@command
        settings = patch.apply(settings)
        if (session != 0L) NativeCore.sessionSetSettings(session, settings.toJson())
        publish()
    }

    override fun focus(id: ControllerId?) {}
    override fun setGlobalOptions(patch: GlobalOptionsPatch) {}
    /** WASAPI 环回不需要授权 */
    override fun provideCaptureConsent(consent: CaptureConsent) {}
    override fun requestDeviceAccess(id: ControllerId) {}

    private fun tick() {
        val now = System.nanoTime()
        val dt = ((now - lastTickNanos) / 1e9).toFloat().coerceIn(0.001f, 0.1f)
        lastTickNanos = now
        // 电平 = 强度之后的震动值，会话只在带「震动」标志时才算；W5 还没有手柄，算出来只用来显示
        NativeCore.sessionTick(session, core, NativeCore.F_VIBRATION or NativeCore.F_LIGHTS, 0f, 0f, dt, 0.0, tickOut)
        tickCount++
        if (tickCount % 3 == 0L) _meters.value = mapOf(ID to Meter(tickOut[NativeCore.T_LEVEL_L], tickOut[NativeCore.T_LEVEL_R]))
        if (tickCount % 25 == 0L) pollCapture()
    }

    private fun pollCapture() {
        NativeCore.captureState(captureHandle, captureInfo)
        val next = when {
            captureInfo[0] == 1 -> CaptureStatus.Running
            captureInfo[4] != 0 -> CaptureStatus.Failed(Bilingual(
                "系统声音采集失败（0x%08X），正在重试".format(captureInfo[4]),
                "Audio capture failed (0x%08X), retrying".format(captureInfo[4])))
            else -> CaptureStatus.Starting
        }
        if (next != capture) {
            capture = next
            publish()
        }
    }

    private fun publish() {
        val info = ControllerInfo(
            id = ID,
            name = "System audio (W5)",
            link = null,
            battery = null,
            capabilities = Capabilities(isDualSense = false, hasLight = false, hasAdaptiveTriggers = false,
                                        hasHD = false, hasSpeaker = false, canVibrate = false),
            settings = settings,
            status = SessionStatus(
                isActive = running,
                engineName = if (running) Bilingual("只采集、显示电平（W5 测试）", "Capture + meters only (W5 test)") else Bilingual.DASH,
                error = null,
            ),
            audioStats = if (running && captureInfo[1] > 0) "loopback ${captureInfo[1]} Hz · ${captureInfo[2]} ch · reopen ${captureInfo[3]}" else null,
        )
        _state.value = EngineState(running = running, canStart = settings.enabled, capture = capture, controllers = listOf(info))
    }

    private fun command(block: () -> Unit) { executor.execute { safely(block) } }

    private fun safely(block: () -> Unit) {
        try { block() } catch (t: Throwable) { System.err.println("[cv-engine] ${t.stackTraceToString()}") }
    }

    private companion object { const val ID: ControllerId = "w5:system-audio" }
}
