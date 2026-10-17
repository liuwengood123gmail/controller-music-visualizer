package app.cmv.engine

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

// 界面与底层之间的「引擎接口」（docs/cross-platform-design.md §4.2），与 Swift 版
// Sources/ControllerCore/EngineAPI.swift 一一对应；Android 多了采集授权和设备授权两个命令。
// 界面只通过它操作底层：发命令、订阅状态快照 / 电平 / 事件；底层不引用任何界面类型。

/** 接口版本：数据结构或语义变化时递增 */
const val ENGINE_API_VERSION = 1

/** 会话的稳定编号；手柄在 USB ↔ 蓝牙之间切换时不变 */
typealias ControllerId = String

/** 中英对照文字：引擎产生的状态 / 错误文字带两份，界面按当前语言取 */
data class Bilingual(val zh: String, val en: String) {
    fun text(language: Language) = if (language == Language.ZH) zh else en

    companion object { val DASH = Bilingual("—", "—") }
}

enum class Language { ZH, EN }

enum class LinkKind(val title: Bilingual) {
    USB(Bilingual("USB", "USB")), BLUETOOTH(Bilingual("蓝牙", "Bluetooth"))
}

data class Battery(val level: Int, val charging: Boolean)

/** 手柄能力：界面据此隐藏不支持的设置项（多手柄文档 D8） */
data class Capabilities(
    val isDualSense: Boolean,
    val hasLight: Boolean,
    val hasAdaptiveTriggers: Boolean,
    /** HD 震动（USB DualSense） */
    val hasHD: Boolean,
    /** 手柄扬声器同步播放（USB DualSense，且能发 HID 报告） */
    val hasSpeaker: Boolean,
    val canVibrate: Boolean,
)

data class SessionStatus(
    val isActive: Boolean,
    /** 例如「HD 震动（USB）+ 手柄扬声器」；没在运行时是「—」 */
    val engineName: Bilingual,
    val error: Bilingual?,
)

/** 手柄扬声器相对手机自己播放的延迟分解（毫秒） */
data class LatencyBreakdown(
    val captureMs: Double,
    val marginMs: Double,
    val controllerOutputMs: Double,
) {
    val controllerTotalMs: Double get() = captureMs + marginMs + controllerOutputMs
}

/** 设备授权：用户授权后能解锁更多功能（Android：USB 直连、Android 17 的 HID 访问） */
data class DeviceAccess(
    /** 说明授权后能得到什么、有什么代价 */
    val hint: Bilingual,
    /** 需要界面先申请的运行时权限（例如 android.permission.ACCESS_HID）；null = 引擎自己弹系统对话框 */
    val runtimePermission: String?,
)

data class ControllerInfo(
    val id: ControllerId,
    /** 设备名，例如「DualSense」「Pro Controller」 */
    val name: String,
    val link: LinkKind?,
    val battery: Battery?,
    val capabilities: Capabilities,
    /** 引擎持有的当前设置（唯一真源） */
    val settings: ControllerSettings,
    val status: SessionStatus,
    val latency: LatencyBreakdown? = null,
    /** 调试信息：音频缓冲、余量、欠载次数等 */
    val audioStats: String? = null,
    /** 随机按摩当前轮播到的预设 */
    val randomNow: MassagePreset? = null,
    /** 可选的设备授权（null = 已经是最完整的控制方式） */
    val access: DeviceAccess? = null,
) {
    /** 下拉框里的名称：「DualSense · USB · 95%」 */
    fun title(language: Language): String =
        listOfNotNull(name, link?.title?.text(language), battery?.let { "${it.level}%" }).joinToString(" · ")
}

/** 系统声音采集的状态 */
sealed interface CaptureStatus {
    data object Off : CaptureStatus
    /** 需要用户在系统弹窗里同意（Android：屏幕录制 / 投屏）。界面看到它就弹窗，结果交给 provideCaptureConsent */
    data object NeedsConsent : CaptureStatus
    /** 已同意，正在启动 */
    data object Starting : CaptureStatus
    data object Running : CaptureStatus
    data class Failed(val reason: Bilingual) : CaptureStatus
}

/** 全局选项（不属于某个手柄） */
data class GlobalOptions(
    /** A 档兼容震动的更新间隔（毫秒）：系统震动 API 每次调用都会重新开始一段效果，太频繁会断续 */
    val rumbleUpdateMs: Int = 40,
)

data class GlobalOptionsPatch(val rumbleUpdateMs: Int? = null) {
    fun apply(o: GlobalOptions) = o.copy(rumbleUpdateMs = (rumbleUpdateMs ?: o.rumbleUpdateMs).coerceIn(10, 200))
}

/** 引擎的状态快照（低频：有变化才发） */
data class EngineState(
    /** 全局「开始」是否按下（D3） */
    val running: Boolean = false,
    /** 至少有一个启用、且 App 要控制点什么的手柄 */
    val canStart: Boolean = false,
    val capture: CaptureStatus = CaptureStatus.Off,
    val controllers: List<ControllerInfo> = emptyList(),
    val notice: Bilingual? = null,
    val error: Bilingual? = null,
    val options: GlobalOptions = GlobalOptions(),
) {
    fun controller(id: ControllerId?): ControllerInfo? = id?.let { i -> controllers.firstOrNull { it.id == i } }
}

/** 电平（约 30Hz）：只给电平条用 */
data class Meter(val left: Float, val right: Float) {
    companion object { val ZERO = Meter(0f, 0f) }
}

/** 一次性事件 */
sealed interface EngineEvent {
    data class ControllerConnected(val id: ControllerId) : EngineEvent
    data class ControllerDisconnected(val id: ControllerId) : EngineEvent
    /** 需要一个运行时权限（界面申请后再调一次 requestDeviceAccess） */
    data class NeedsPermission(val id: ControllerId, val permission: String) : EngineEvent
}

/** 平台相关的采集授权结果（Android：MediaProjection 弹窗的 resultCode + data Intent） */
data class CaptureConsent(val granted: Boolean, val resultCode: Int = 0, val data: Any? = null)

/**
 * 引擎接口。命令可以在任意线程调用，引擎内部串行处理；state / meters / events 可在任意线程收集。
 */
interface ControllerEngine {
    val apiVersion: Int get() = ENGINE_API_VERSION

    val state: StateFlow<EngineState>
    val meters: StateFlow<Map<ControllerId, Meter>>
    val events: SharedFlow<EngineEvent>

    /** 全局开始 / 停止（D3） */
    fun start()
    fun stop()

    /** 只改补丁里给出的字段 */
    fun updateSettings(id: ControllerId, patch: SettingsPatch)

    /** 界面当前选中的手柄：只用作「新手柄复制谁的设置」（D5） */
    fun focus(id: ControllerId?)

    fun setGlobalOptions(patch: GlobalOptionsPatch)

    /** 采集授权的结果（对应 CaptureStatus.NeedsConsent） */
    fun provideCaptureConsent(consent: CaptureConsent)

    /** 申请更完整的设备控制（ControllerInfo.access）。需要运行时权限时先发 NeedsPermission 事件 */
    fun requestDeviceAccess(id: ControllerId)
}
