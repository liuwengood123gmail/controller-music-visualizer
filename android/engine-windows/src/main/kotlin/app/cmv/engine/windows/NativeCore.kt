package app.cmv.engine.windows

import java.io.File

/**
 * Swift 核心（ControllerCAPI.dll）经 JNI 层（cvwin.dll，native-win/src）的调用。
 * 从 android/engine 的 NativeCore.kt 复制：核心 / 会话 / 报告 / 渲染器 / 字符串部分与 Android 相同；
 * 平台部分换成 Windows 的（采集、定时；手柄音频 / HID / XInput 在 W6 加）。
 *
 * DLL 用绝对路径加载（docs/windows-plan.md §5.3）：目录取 -Dcv.native.dir，打包后取 Compose 的资源目录。
 */
object NativeCore {
    val nativeDir: File? = listOfNotNull(System.getProperty("cv.native.dir"), System.getProperty("compose.application.resources.dir"))
        .map(::File).firstOrNull { File(it, "cvwin.dll").isFile }

    init {
        val dir = nativeDir ?: throw UnsatisfiedLinkError(
            "cvwin.dll not found (cv.native.dir=${System.getProperty("cv.native.dir")}); build native-win first")
        System.load(File(dir, "cvwin.dll").absolutePath)
    }

    // tick 输出数组下标（与 Swift 的 CVTick 相同）
    const val T_INTENSITY = 0; const val T_RESISTANCE = 1; const val T_MOTOR_L = 2; const val T_MOTOR_R = 3
    const val T_HD = 4; const val T_HD_L = 5; const val T_HD_R = 6; const val T_HD_FREQ = 7; const val T_HD_MUSIC = 8
    const val T_LIGHT = 9; const val T_RED = 10; const val T_GREEN = 11; const val T_BLUE = 12; const val T_LEDS = 13
    const val T_LEVEL_L = 14; const val T_LEVEL_R = 15; const val T_RANDOM_NOW = 16
    const val TICK_COUNT = 17

    const val F_VIBRATION = 1; const val F_TRIGGERS = 2; const val F_LIGHTS = 4
    const val F_ADAPTIVE_TRIGGERS = 8; const val F_PLAYER_LEDS = 16; const val F_HD_ACTIVE = 32

    external fun apiVersion(): Int

    external fun coreCreate(highpassHz: Float): Long
    external fun coreDestroy(core: Long)
    external fun coreReset(core: Long)
    external fun coreProcess(core: Long, interleaved: FloatArray, frames: Int, sampleRate: Float)

    external fun sessionCreate(): Long
    external fun sessionDestroy(s: Long)
    external fun sessionReset(s: Long)
    external fun sessionSetSettings(s: Long, json: String): Int
    external fun sessionTick(s: Long, core: Long, flags: Int, triggerLeft: Float, triggerRight: Float, dt: Float,
                             alignDelayMs: Double, out: FloatArray)
    external fun alignDelayMs(hdActive: Boolean, speakerOn: Boolean, marginMs: Double, controllerOutputMs: Double,
                              overrideMs: Double): Double

    external fun dsCreate(bluetooth: Boolean): Long
    external fun dsDestroy(h: Long)
    external fun dsSetControls(h: Long, rumble: Boolean, triggers: Boolean, lights: Boolean)
    external fun dsSetHd(h: Long, on: Boolean)
    external fun dsSetSpeaker(h: Long, on: Boolean, hwVolume: Int, preamp: Int)
    external fun dsSetTriggerResistance(h: Long, v: Float)
    external fun dsSetLight(h: Long, r: Float, g: Float, b: Float)
    external fun dsSetPlayerLeds(h: Long, mask: Int)
    external fun dsSetMotors(h: Long, l: Float, r: Float)
    external fun dsSend(h: Long)
    external fun dsStop(h: Long)
    /** 取出一份待发送的报告（含报告 ID），返回长度；0 = 没有 */
    external fun dsTakeReport(h: Long, out: ByteArray): Int
    /** bytes 以报告 ID 开头；out = [L2, R2, 电量, 充电] */
    external fun dsParseInput(reportId: Int, bytes: ByteArray, length: Int, out: FloatArray): Boolean

    external fun rendererCreate(core: Long, sampleRate: Float, haptics: Boolean, bufferMs: Double, hapticsDelayMs: Double): Long
    external fun rendererDestroy(h: Long)
    external fun rendererSet(h: Long, l: Float, r: Float, freq: Float, useMusic: Boolean)
    external fun rendererSetSpeakerVolume(h: Long, volume: Float)
    external fun rendererMute(h: Long)
    external fun rendererSpeakerAudible(h: Long): Boolean
    /** out = [余量 ms, 欠载次数] */
    external fun rendererStats(h: Long, out: DoubleArray)

    external fun settingsInitial(remembered: String?, copying: String?): String
    external fun settingsApplyPatch(settings: String, patch: String): String
    external fun reconcile(json: String): String

    // MARK: Windows 平台

    /** 开始 WASAPI 环回采集（默认输出设备），采集线程直接调 coreProcess；默认设备切换时自动重开 */
    external fun captureStart(core: Long): Long
    /** state = [运行中, 采样率, 声道数, 重开次数, 最后一次错误 HRESULT] */
    external fun captureState(h: Long, state: IntArray)
    external fun captureStop(h: Long)
    /** timeBeginPeriod(1) / timeEndPeriod(1)：10ms 主循环需要 1ms 计时精度 */
    external fun highResTimer(enable: Boolean)
}
