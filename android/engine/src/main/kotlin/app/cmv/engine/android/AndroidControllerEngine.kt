package app.cmv.engine.android

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.input.InputManager
import android.hardware.usb.UsbManager
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import androidx.core.content.ContextCompat
import app.cmv.engine.Bilingual
import app.cmv.engine.CaptureConsent
import app.cmv.engine.CaptureStatus
import app.cmv.engine.ControllerEngine
import app.cmv.engine.ControllerId
import app.cmv.engine.ControllerSettings
import app.cmv.engine.EngineEvent
import app.cmv.engine.EngineState
import app.cmv.engine.GlobalOptions
import app.cmv.engine.GlobalOptionsPatch
import app.cmv.engine.Meter
import app.cmv.engine.SettingsPatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Android 的真实引擎（实现 engine-api 的 [ControllerEngine]）。
 * 所有状态都只在一个引擎线程上读写（命令、设备变化、10ms 主循环都排到这个线程），状态快照经 StateFlow 发给界面。
 * 系统声音采集一份、所有手柄共用（Swift 核心的分析器 + 扬声器缓冲）。
 */
class AndroidControllerEngine(context: Context) : ControllerEngine {
    private val app = context.applicationContext
    private val executor = Executors.newSingleThreadScheduledExecutor { Thread(it, "cv-engine").apply { priority = Thread.MAX_PRIORITY } }
    private val main = Handler(Looper.getMainLooper())
    private val discovery = Discovery(app)
    private val store = SettingsStore(app)
    private val usbManager = app.getSystemService(UsbManager::class.java)
    private val core = NativeCore.coreCreate(200f)

    private val _state = MutableStateFlow(EngineState())
    private val _meters = MutableStateFlow<Map<ControllerId, Meter>>(emptyMap())
    private val _events = MutableSharedFlow<EngineEvent>(extraBufferCapacity = 16)
    override val state: StateFlow<EngineState> = _state
    override val meters: StateFlow<Map<ControllerId, Meter>> = _meters
    override val events: SharedFlow<EngineEvent> = _events

    // 以下只在引擎线程上访问
    private var sessions = listOf<Session>()
    private var focusedId: ControllerId? = null
    private var running = false
    private var capture: CaptureStatus = CaptureStatus.Off
    private var notice: Bilingual? = null
    private var error: Bilingual? = null
    private var options = GlobalOptions()
    private var projection: MediaProjection? = null
    private var playback: PlaybackCapture? = null
    private var pendingConsent: CaptureConsent? = null
    /** 停止后保留录屏授权的期限到了就释放（见 stopEngine） */
    private var projectionRelease: ScheduledFuture<*>? = null
    private var ticker: ScheduledFuture<*>? = null
    private var lastTick = 0L
    private var frame = 0
    private var dirty = false
    private var saveScheduled = false
    private var hidOpening = false

    init {
        val im = app.getSystemService(InputManager::class.java)
        im.registerInputDeviceListener(object : InputManager.InputDeviceListener {
            override fun onInputDeviceAdded(id: Int) = post { refresh() }
            override fun onInputDeviceRemoved(id: Int) = post { refresh() }
            override fun onInputDeviceChanged(id: Int) = post { refresh() }
        }, main)
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(ACTION_USB_PERMISSION)
        }
        ContextCompat.registerReceiver(app, object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                post {
                    refresh()
                    if (i.action == ACTION_USB_PERMISSION) sessions.forEach { it.capabilitiesChanged() }
                    publish()
                }
            }
        }, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        // 电量每 5 秒刷新一次；顺便再对一次连接情况，补上没有通知的插拔
        executor.scheduleWithFixedDelay({ safely { refresh(); sessions.forEach { it.refreshBattery(); it.refreshLatency() }; markDirty() } },
                                        1, 5, TimeUnit.SECONDS)
        post { refresh(); publish() }
    }

    private fun post(block: () -> Unit) { executor.execute { safely(block) } }

    private inline fun safely(block: () -> Unit) {
        try { block() } catch (t: Throwable) { Log.e(TAG, "engine error", t) }
    }

    // MARK: - 命令（任意线程）

    override fun start() = post {
        if (running) return@post
        if (sessions.none { it.settings.enabled && !it.allLeftToGame }) {
            error = if (sessions.isEmpty()) Bilingual("没有找到手柄", "No controller found") else Bilingual("没有启用的手柄", "No controller enabled")
            publish(); return@post
        }
        error = null
        running = true
        projectionRelease?.cancel(false); projectionRelease = null
        EngineService.start(app)
        sessions.forEach { it.rumbleUpdateMs = options.rumbleUpdateMs; it.arm() }
        updateCapture()
        lastTick = SystemClock.elapsedRealtimeNanos()
        ticker = executor.scheduleAtFixedRate({ safely { tick() } }, 0, 10, TimeUnit.MILLISECONDS)
        publish()
    }

    /** 界面的「停止」：录屏授权保留 PROJECTION_KEEP_MINUTES 分钟，期间再开始不用重新同意 */
    override fun stop() = post { stopEngine(release = false, keepMinutes = PROJECTION_KEEP_MINUTES) }

    /** 通知栏的「停止 / 退出」：同时释放录屏授权、结束前台服务 */
    internal fun stopAndRelease() = post { stopEngine(release = true, keepMinutes = 0) }

    private fun stopEngine(release: Boolean, keepMinutes: Long) {
        if (running) {
            running = false
            ticker?.cancel(false); ticker = null
            pauseCapture()
            notice = null
            sessions.forEach { it.disarm() }
            saveAll()
            _meters.value = emptyMap()
        }
        if (release || projection == null) {
            releaseProjection()
        } else {
            // 系统要求持有 MediaProjection 时前台服务一直在；通知改成「已暂停」，带「退出」按钮
            EngineService.paused(app)
            projectionRelease?.cancel(false)
            projectionRelease = executor.schedule({ safely { if (!running) { releaseProjection(); publish() } } },
                                                  keepMinutes, TimeUnit.MINUTES)
        }
        publish()
    }

    override fun updateSettings(id: ControllerId, patch: SettingsPatch) = post {
        val s = sessions.firstOrNull { it.id == id } ?: return@post
        s.apply(patch.apply(s.settings))
        updateCapture()
        scheduleSave()
        publish()
    }

    override fun focus(id: ControllerId?) = post { focusedId = id }

    override fun setGlobalOptions(patch: GlobalOptionsPatch) = post {
        options = patch.apply(options)
        sessions.forEach { it.rumbleUpdateMs = options.rumbleUpdateMs }
        publish()
    }

    override fun provideCaptureConsent(consent: CaptureConsent) = post {
        if (capture != CaptureStatus.NeedsConsent) return@post
        if (!consent.granted || consent.data !is Intent) {
            captureFailed(Bilingual("没有获得屏幕录制授权", "Screen capture was not allowed"))
            return@post
        }
        // Android 14+：必须先以 mediaProjection 类型进入前台服务，才能拿到 MediaProjection
        pendingConsent = consent
        capture = CaptureStatus.Starting
        EngineService.startProjection(app)
        publish()
    }

    override fun requestDeviceAccess(id: ControllerId) = post {
        val s = sessions.firstOrNull { it.id == id } ?: return@post
        if (!s.isDualSense) return@post
        if (Hid17.supported) {
            if (!Hid17.granted(app)) { _events.tryEmit(EngineEvent.NeedsPermission(id, Hid17.PERMISSION)); return@post }
            openHid17(); return@post
        }
        val usb = s.found.usb ?: return@post
        if (usbManager.hasPermission(usb)) { s.capabilitiesChanged(); publish(); return@post }
        val pi = PendingIntent.getBroadcast(app, 0, Intent(ACTION_USB_PERMISSION).setPackage(app.packageName),
                                            PendingIntent.FLAG_MUTABLE)
        usbManager.requestPermission(usb, pi)
    }

    // MARK: - 平台入口（Activity / 服务调用）

    /** Activity 在前台时转发手柄的扳机轴（A 档没有 HID 输入报告时用来调强度） */
    fun onMotionEvent(e: MotionEvent) {
        if (e.source and InputDevice.SOURCE_JOYSTICK != InputDevice.SOURCE_JOYSTICK) return
        val l = maxOf(e.getAxisValue(MotionEvent.AXIS_LTRIGGER), e.getAxisValue(MotionEvent.AXIS_BRAKE))
        val r = maxOf(e.getAxisValue(MotionEvent.AXIS_RTRIGGER), e.getAxisValue(MotionEvent.AXIS_GAS))
        val deviceId = e.deviceId
        post { sessions.firstOrNull { it.found.inputDeviceId == deviceId }?.axisTriggers = floatArrayOf(l, r) }
    }

    /** Activity 退到后台：系统不再发扳机轴，清零避免卡在按下状态 */
    fun clearAxes() = post { sessions.forEach { it.axisTriggers = floatArrayOf(0f, 0f) } }

    /** 前台服务已经以 mediaProjection 类型启动（EngineService 调用） */
    internal fun onProjectionForeground() = post {
        val consent = pendingConsent ?: return@post
        pendingConsent = null
        try {
            val mpm = app.getSystemService(MediaProjectionManager::class.java)
            val p = mpm.getMediaProjection(consent.resultCode, consent.data as Intent)
                ?: throw IllegalStateException("getMediaProjection returned null")
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() = post {
                    if (projection !== p) return@post
                    projection = null
                    stopCapture()
                    // 用户在状态栏停止了共享：运行中按采集失败处理；已停止时直接结束前台服务
                    if (running) captureFailed(Bilingual("屏幕录制已被系统停止", "Screen capture was stopped by the system"))
                    else { projectionRelease?.cancel(false); projectionRelease = null; EngineService.stop(app); publish() }
                }
            }, main)
            projection = p
            startPlayback(p)
        } catch (t: Throwable) {
            Log.e(TAG, "capture start failed", t)
            captureFailed(Bilingual("无法读取系统声音：${t.message}", "Cannot read system audio: ${t.message}"))
        }
        publish()
    }

    /** 调试入口：adb shell am start-foreground-service … --es cmd …（见 EngineService） */
    internal fun debugCommand(cmd: String, target: String?, json: String?) = post {
        when (cmd) {
            "start" -> start()
            "stop" -> stop()
            "set" -> {
                val s = target?.toIntOrNull()?.let { sessions.getOrNull(it) } ?: sessions.firstOrNull { it.id == target } ?: sessions.firstOrNull()
                if (s != null && json != null) {
                    val patch = SettingsPatch.fromJson(Json.parseToJsonElement(json).jsonObject)
                    updateSettings(s.id, patch)
                }
            }
            "access" -> sessions.firstOrNull()?.let { requestDeviceAccess(it.id) }
        }
        post { Log.i(TAG, "state: ${_state.value}") }
    }

    // MARK: - 采集

    private val needsAudio get() = running && sessions.any { it.needsAudio }

    /**
     * 需要系统声音时：手上还有录屏授权（上次停止后保留的）就直接用，否则请界面去征得同意。
     * 采集一旦起来，运行期间就保持（每次重新申请都要用户再点一次同意）
     */
    private fun updateCapture() {
        if (needsAudio && capture == CaptureStatus.Off) {
            val p = projection
            if (p == null || !runCatching { startPlayback(p) }.onFailure { Log.w(TAG, "reuse projection failed", it) }.isSuccess) {
                if (p != null) { projection = null; runCatching { p.stop() } }
                capture = CaptureStatus.NeedsConsent
            }
        } else if (!needsAudio && capture == CaptureStatus.NeedsConsent) {
            capture = CaptureStatus.Off
        }
    }

    private fun captureFailed(reason: Bilingual) {
        stopCapture()
        capture = CaptureStatus.Failed(reason)
        error = Bilingual("${reason.zh}。跟随音乐不可用（按摩照常）；停止后重新开始可以再试一次。",
                          "${reason.en}. Music mode is unavailable (massage still works); stop and start again to retry.")
        publish()
    }

    /** 用已有的录屏授权开始读取系统声音（失败抛异常） */
    private fun startPlayback(p: MediaProjection) {
        NativeCore.coreReset(core)
        val c = PlaybackCapture(p, core) { why -> post { captureFailed(Bilingual("读取系统声音出错：$why", "Audio capture error: $why")) } }
        c.start()
        playback = c
        capture = CaptureStatus.Running
        notice = null
        sessions.forEach { it.refreshLatency() }
    }

    /** 停止读取系统声音，录屏授权保留 */
    private fun pauseCapture() {
        playback?.stop(); playback = null
        pendingConsent = null
        capture = CaptureStatus.Off
    }

    /** 释放录屏授权并结束前台服务 */
    private fun releaseProjection() {
        projectionRelease?.cancel(false); projectionRelease = null
        stopCapture()
        EngineService.stop(app)
    }

    private fun stopCapture() {
        playback?.stop(); playback = null
        projection?.let { p -> projection = null; runCatching { p.stop() } }
        pendingConsent = null
        capture = CaptureStatus.Off
    }

    // MARK: - 会话列表（对账规则在 Swift 的 SessionReconciler 里）

    private fun refresh() {
        val found = discovery.discover()
        val input = JsonObject(mapOf(
            "existing" to JsonArray(sessions.map { identityJson(it.identity) }),
            "found" to JsonArray(found.map { identityJson(it.identity) }),
        ))
        val plan = runCatching { Json.parseToJsonElement(NativeCore.reconcile(input.toString())).jsonObject }.getOrNull() ?: return
        val result = mutableListOf<Session>()
        val added = mutableListOf<Session>()
        for (slot in plan["slots"]!!.jsonArray) {
            val o = slot.jsonObject
            val type = o["type"]!!.jsonPrimitive.content
            val f = found[o["found"]!!.jsonPrimitive.int]
            when (type) {
                "keep" -> { val s = sessions[o["session"]!!.jsonPrimitive.int]; s.update(f); result += s }
                "migrate" -> {
                    // 同一台 DualSense 换了连接方式：记住旧身份下的设置，会话沿用
                    val s = sessions[o["session"]!!.jsonPrimitive.int]
                    store.save(mapOf(s.identity.key to s.settings)); s.update(f); result += s
                }
                else -> {
                    val remembered = store.load(f.identity.key)
                    val copying = sessions.firstOrNull { it.id == focusedId }?.settings ?: sessions.firstOrNull()?.settings
                    val s = Session(app, f, ControllerSettings.initial(remembered, copying), core) { playback?.latencyMs }
                    s.rumbleUpdateMs = options.rumbleUpdateMs
                    s.refreshBattery()
                    added += s; result += s
                }
            }
        }
        val removed = plan["removed"]!!.jsonArray.map { sessions[it.jsonPrimitive.int] }
        if (removed.isNotEmpty()) store.save(removed.associate { it.identity.key to it.settings })
        removed.forEach { it.retire() }
        sessions = result
        if (running) added.forEach { it.arm() }
        // 手柄全部断开：录屏授权只短暂保留（马上插回 / USB ↔ 蓝牙切换不用重新同意），之后状态栏的「屏幕共享中」就消失
        if (sessions.isEmpty() && running) stopEngine(release = false, keepMinutes = PROJECTION_KEEP_AFTER_DISCONNECT_MINUTES)
        if (plan["changed"]!!.jsonPrimitive.boolean || added.isNotEmpty()) {
            removed.forEach { _events.tryEmit(EngineEvent.ControllerDisconnected(it.id)) }
            added.forEach { _events.tryEmit(EngineEvent.ControllerConnected(it.id)) }
            updateCapture()
            markDirty()
        }
        if (Hid17.granted(app) && sessions.any { it.isDualSense && it.hid17 == null }) openHid17()
    }

    private fun identityJson(i: Identity) = JsonObject(mapOf("kind" to JsonPrimitive(i.kind), "key" to JsonPrimitive(i.key)))

    /** Android 17：打开可访问的 DualSense，按连接方式和顺序交给对应的会话 */
    private fun openHid17() {
        if (!Hid17.granted(app) || hidOpening || Build.VERSION.SDK_INT < 37) return
        val devices = Hid17.dualSenses(app)
        val targets = sessions.filter { it.isDualSense && it.hid17 == null }
        if (devices.isEmpty() || targets.isEmpty()) return
        hidOpening = true
        var remaining = devices.size
        val usbQueue = targets.filter { !it.found.bluetooth }.toMutableList()
        val btQueue = targets.filter { it.found.bluetooth }.toMutableList()
        for (d in devices) {
            val queue = if (Hid17.isBluetooth(d)) btQueue else usbQueue
            val s = queue.removeFirstOrNull()
            if (s == null) { remaining--; continue }
            Hid17Link.open(d) { link ->
                post {
                    if (link != null && s in sessions) { s.hid17 = link; s.capabilitiesChanged() }
                    if (--remaining <= 0) hidOpening = false
                    publish()
                }
            }
        }
        if (remaining <= 0) hidOpening = false
    }

    // MARK: - 每 10ms 一次

    private fun tick() {
        val now = SystemClock.elapsedRealtimeNanos()
        val dt = ((now - lastTick) / 1e9).toFloat().coerceIn(0f, 0.1f)
        lastTick = now
        frame++
        for (s in sessions) if (s.tick(dt, frame)) { dirty = true; scheduleSave() }
        // 电平和状态约 33Hz 发给界面
        if (frame % 3 == 0) {
            _meters.value = sessions.filter { it.isActive }.associate { it.id to Meter(it.level[0], it.level[1]) }
            if (dirty) publish()
        }
    }

    // MARK: - 状态快照

    private fun markDirty() { if (running) dirty = true else publish() }

    private fun publish() {
        dirty = false
        val cs = sessions.map { it.info() }
        _state.value = EngineState(running = running, canStart = sessions.any { it.settings.enabled && !it.allLeftToGame },
                                   capture = capture, controllers = cs, notice = notice, error = error, options = options)
    }

    private fun scheduleSave() {
        if (saveScheduled) return
        saveScheduled = true
        executor.schedule({ safely { saveScheduled = false; saveAll() } }, 1, TimeUnit.SECONDS)
    }

    private fun saveAll() = store.save(sessions.associate { it.identity.key to it.settings })

    companion object {
        const val TAG = "cv-engine"
        /** 停止后录屏授权保留多久（期间再开始不用重新同意；状态栏会一直显示共享图标） */
        const val PROJECTION_KEEP_MINUTES = 30L
        /** 手柄全部断开导致的停止：授权只保留这么久 */
        const val PROJECTION_KEEP_AFTER_DISCONNECT_MINUTES = 1L
        const val ACTION_USB_PERMISSION = "app.cmv.USB_PERMISSION"

        @Volatile private var instance: AndroidControllerEngine? = null

        /** 进程内单例：界面关掉后引擎（和前台服务）继续跑 */
        fun get(context: Context): AndroidControllerEngine =
            instance ?: synchronized(this) { instance ?: AndroidControllerEngine(context).also { instance = it } }

        internal fun existing(): AndroidControllerEngine? = instance

    }
}
