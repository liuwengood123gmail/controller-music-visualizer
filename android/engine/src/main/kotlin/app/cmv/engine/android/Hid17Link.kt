package app.cmv.engine.android

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.hid.HidDevice
import android.hardware.hid.HidEventListener
import android.hardware.hid.HidManager
import android.hardware.hid.Report
import android.os.Build
import android.os.OutcomeReceiver
import android.util.Log
import androidx.annotation.RequiresApi
import java.nio.ByteBuffer
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * B 档（Android 17 / API 37.2+）：系统的 HidManager / HidDevice，需要用户授予 ACCESS_HID。
 * 不抢占内核驱动（系统照样能用手柄的按键），USB 和蓝牙都能发完整的 DualSense 报告。
 */
object Hid17 {
    /** 37.2 = Android 17 的第二个小版本（HidManager 在这一版加入） */
    private const val SDK_FULL_37_2 = 37 * 100_000 + 2

    val supported: Boolean get() = Build.VERSION.SDK_INT >= 37 && Build.VERSION.SDK_INT_FULL >= SDK_FULL_37_2

    const val PERMISSION = "android.permission.ACCESS_HID"

    fun granted(context: Context) = supported &&
        context.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED

    /** 当前可访问的 DualSense（没有权限或版本不够时为空） */
    @RequiresApi(37)
    fun dualSenses(context: Context): List<HidDevice> {
        if (!granted(context)) return emptyList()
        val m = context.getSystemService(HidManager::class.java) ?: return emptyList()
        return runCatching {
            if (!m.canEnumerateDevices()) emptyList()
            else m.devices.filter { Discovery.isDualSense(it.vendorId, it.productId) }
        }.getOrDefault(emptyList())
    }

    @RequiresApi(37)
    fun isBluetooth(d: HidDevice) = d.transport == HidDevice.TRANSPORT_BLUETOOTH

}

@RequiresApi(37)
class Hid17Link private constructor(private val device: HidDevice) : InputParser(), DualSenseLink {
    override val bluetooth = Hid17.isBluetooth(device)
    override val description = app.cmv.engine.Bilingual(
        if (bluetooth) "直接控制（HID · 蓝牙）" else "直接控制（HID · USB）",
        if (bluetooth) "Direct control (HID · Bluetooth)" else "Direct control (HID · USB)")
    @Volatile private var failures = 0

    private val listener = object : HidEventListener {
        override fun onInputReport(report: Report) {
            val data = report.data
            val n = data.remaining()
            val bytes = ByteArray(n + 1)
            bytes[0] = report.reportId.toByte()
            data.duplicate().get(bytes, 1, n)
            onInput(report.reportId, bytes, n + 1)
        }
        override fun onDisconnected() { failures = 1000 }
        override fun onError(e: Exception) { Log.w("cv-engine", "HID error", e) }
    }

    init { device.registerEventListener(callbacks, listener) }

    override fun send(report: ByteArray, length: Int): Boolean {
        if (failures > 50) return false
        // Report 的数据不含报告 ID
        val r = Report(report[0].toInt() and 0xFF, ByteBuffer.wrap(report.copyOfRange(1, length)))
        device.sendOutputReport(r, callbacks, object : OutcomeReceiver<Void, Exception> {
            override fun onResult(result: Void?) { failures = 0 }
            override fun onError(error: Exception) { failures++ }
        })
        return true
    }

    override fun close() {
        runCatching { device.unregisterEventListener(listener) }
        runCatching { device.close() }
    }

    companion object {
        /** 报告的发送回调在单独的线程上，不占引擎线程 */
        private val callbacks: Executor = Executors.newSingleThreadExecutor { Thread(it, "cv-hid").apply { isDaemon = true } }

        /** 异步打开；结果在回调线程 */
        fun open(device: HidDevice, done: (Hid17Link?) -> Unit) {
            if (device.isOpen) { done(Hid17Link(device)); return }
            device.open(callbacks, object : OutcomeReceiver<HidDevice, Exception> {
                override fun onResult(result: HidDevice) { done(Hid17Link(result)) }
                override fun onError(error: Exception) { Log.w("cv-engine", "HID open failed", error); done(null) }
            })
        }
    }
}
