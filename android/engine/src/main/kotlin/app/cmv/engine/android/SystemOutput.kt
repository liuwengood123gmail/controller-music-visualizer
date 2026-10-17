package app.cmv.engine.android

import android.graphics.Color
import android.hardware.lights.Light
import android.hardware.lights.LightState
import android.hardware.lights.LightsManager
import android.hardware.lights.LightsRequest
import android.os.Build
import android.os.CombinedVibration
import android.os.VibrationEffect
import android.os.VibratorManager
import android.os.SystemClock
import android.view.InputDevice
import androidx.annotation.RequiresApi
import app.cmv.engine.Battery
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * A 档（Android 12+，任何系统识别的手柄）：系统的 VibratorManager（两个马达）和 LightsManager（RGB 灯条、玩家指示灯）。
 *
 * 系统震动 API 每次调用都会重新开始一段效果，每 10ms 调一次会断续，所以按 [updateMs] 的间隔更新，
 * 每段效果持续 3 个间隔，下一次更新时接上（docs/cross-platform-design.md §3.3 的备选方案）。
 */
@RequiresApi(31)
class SystemOutput(private val device: InputDevice, var updateMs: Int) {
    private val vm: VibratorManager = device.vibratorManager
    private val ids: IntArray = vm.vibratorIds
    private val amplitudeControl = ids.all { vm.getVibrator(it).hasAmplitudeControl() }
    private val lightsManager: LightsManager = device.lightsManager
    private val lights: List<Light> = lightsManager.lights
    private val rgbLights = lights.filter { it.hasRgbControl() }
    private val playerLights = lights.filter { it.type == Light.LIGHT_TYPE_PLAYER_ID }
    private var lightSession: LightsManager.LightsSession? = null

    private var lastVibrate = 0L
    private var lastAmp = intArrayOf(-1, -1)
    private var lastLight = 0L
    private var lastColor = 0
    private var lastPlayer = -1

    val canVibrate get() = ids.isNotEmpty()
    val hasLight get() = rgbLights.isNotEmpty() || playerLights.isNotEmpty()

    /** 兼容震动：左 = 重马达，右 = 轻马达，0…1。每 10ms 调用，按 updateMs 节流 */
    fun setMotors(left: Float, right: Float) {
        if (ids.isEmpty()) return
        val now = SystemClock.uptimeMillis()
        val l = amp(left); val r = amp(right)
        val stopped = l == 0 && r == 0
        if (stopped && lastAmp[0] == 0 && lastAmp[1] == 0) return
        if (now - lastVibrate < updateMs && !(stopped && (lastAmp[0] != 0 || lastAmp[1] != 0))) return
        lastVibrate = now
        lastAmp = intArrayOf(l, r)
        if (stopped) { vm.cancel(); return }
        val duration = (updateMs * 3).toLong()
        fun effect(a: Int) = VibrationEffect.createWaveform(longArrayOf(duration), intArrayOf(a), -1)
        val combined = if (ids.size >= 2) {
            CombinedVibration.startParallel().addVibrator(ids[0], effect(l)).addVibrator(ids[1], effect(r)).combine()
        } else {
            CombinedVibration.createParallel(effect(maxOf(l, r)))
        }
        runCatching { vm.vibrate(combined) }
    }

    private fun amp(v: Float): Int {
        val c = v.coerceIn(0f, 1f)
        if (!amplitudeControl) return if (c > 0.5f) 255 else 0
        if (c < 0.02f) return 0
        return (compatBoost(c) * 255).roundToInt().coerceIn(1, 255)
    }

    /** 灯条颜色和玩家指示灯（白点电平：亮几颗）。最多每 50ms 更新一次，只在变化时 */
    fun setLights(r: Float, g: Float, b: Float, playerMask: Int?) {
        if (!hasLight) return
        val now = SystemClock.uptimeMillis()
        if (now - lastLight < 50) return
        val color = Color.rgb((r.coerceIn(0f, 1f) * 255).roundToInt(), (g.coerceIn(0f, 1f) * 255).roundToInt(),
                              (b.coerceIn(0f, 1f) * 255).roundToInt())
        val player = playerMask?.let { Integer.bitCount(it).coerceIn(0, 4) } ?: -1
        if (color == lastColor && player == lastPlayer) return
        lastLight = now; lastColor = color; lastPlayer = player
        val req = LightsRequest.Builder()
        rgbLights.forEach { req.addLight(it, LightState.Builder().setColor(color).build()) }
        if (player >= 0) playerLights.forEach { req.addLight(it, LightState.Builder().setPlayerId(player).build()) }
        runCatching {
            val s = lightSession ?: lightsManager.openSession().also { lightSession = it }
            s.requestLights(req.build())
        }
    }

    /** 交出灯光：关掉会话，系统恢复原来的灯 */
    fun releaseLights() {
        runCatching { lightSession?.close() }
        lightSession = null
        lastColor = 0; lastPlayer = -1
    }

    fun stop() {
        runCatching { vm.cancel() }
        lastAmp = intArrayOf(0, 0)
        releaseLights()
    }

    companion object {
        /**
         * 兼容震动（非 HD）的力度曲线：中低段往上抬，0.3 → 0.55、0.5 → 0.71，最大不变。
         * 实测 Android 上兼容震动最大力度够，但跟随音乐时数值多在中低段，体感比 Mac 弱。系统震动和 USB 直连的普通震动都用
         */
        fun compatBoost(v: Float): Float = sqrt(v.coerceIn(0f, 1f))

        /** 调试：两个马达同一强度震 ms 毫秒；restartMs > 0 时每隔 restartMs 重新开始一段（每段 3 个间隔，同 setMotors） */
        @RequiresApi(31)
        fun rumbleTest(device: InputDevice, amp: Int, ms: Int, restartMs: Int) = Thread {
            val vm = device.vibratorManager
            val ids = vm.vibratorIds
            val a = amp.coerceIn(1, 255)
            fun play(duration: Long) {
                val e = VibrationEffect.createOneShot(duration, a)
                val c = if (ids.size >= 2) CombinedVibration.startParallel().addVibrator(ids[0], e).addVibrator(ids[1], e).combine()
                        else CombinedVibration.createParallel(e)
                vm.vibrate(c)
            }
            android.util.Log.i("cv-engine", "rumble test: ids=${ids.toList()} amp=$a ms=$ms restartMs=$restartMs " +
                "amplitudeControl=${ids.map { vm.getVibrator(it).hasAmplitudeControl() }}")
            if (restartMs <= 0) { play(ms.toLong()); Thread.sleep(ms.toLong()) }
            else {
                val end = SystemClock.uptimeMillis() + ms
                while (SystemClock.uptimeMillis() < end) { play(restartMs * 3L); Thread.sleep(restartMs.toLong()) }
            }
            vm.cancel()
        }.start()

        fun battery(device: InputDevice): Battery? {
            if (Build.VERSION.SDK_INT < 31) return null
            val s = device.batteryState
            if (!s.isPresent || s.capacity.isNaN()) return null
            return Battery((s.capacity * 100).roundToInt(), s.status == android.hardware.BatteryState.STATUS_CHARGING)
        }
    }
}
