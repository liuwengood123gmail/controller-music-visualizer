package app.cmv.engine.android

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.SystemClock
import android.util.Log

/** 一台 DualSense 的原始 HID 收发（报告内容由 Swift 核心的 DualSenseOutputController 生成） */
interface DualSenseLink {
    val bluetooth: Boolean
    val description: app.cmv.engine.Bilingual
    /** 发送完整报告（第一个字节是报告 ID） */
    fun send(report: ByteArray, length: Int): Boolean
    /** 最近 0.5 秒内收到的输入：[L2, R2, 电量, 充电]；没有时 null */
    fun freshInput(): FloatArray?
    fun close()
}

/** 输入报告的公共处理：解析后记下来（输入线程写、引擎线程读） */
abstract class InputParser {
    private val parsed = FloatArray(4)
    @Volatile private var latest: FloatArray? = null
    @Volatile private var updated = 0L

    protected fun onInput(reportId: Int, bytes: ByteArray, length: Int) {
        if (NativeCore.dsParseInput(reportId, bytes, length, parsed)) {
            latest = parsed.copyOf()
            updated = SystemClock.uptimeMillis()
        }
    }

    fun freshInput(): FloatArray? = latest?.takeIf { SystemClock.uptimeMillis() - updated < 500 }
}

/**
 * USB 直连（任何 Android 版本）：经 UsbManager 接管手柄的 HID 接口（claimInterface(force = true) 会断开内核驱动），
 * 直接收发报告——扳机阻尼、精确灯光、白灯、HD 模式开关、扬声器通路都能用。
 * 代价：直连期间系统收不到这个手柄的按键；断开后要重新插拔，系统才会重新接管。
 */
class UsbDirectLink private constructor(
    private val connection: UsbDeviceConnection,
    private val intf: UsbInterface,
    private val outEp: UsbEndpoint?,
    private val inEp: UsbEndpoint?,
) : InputParser(), DualSenseLink {
    override val bluetooth = false
    override val description = app.cmv.engine.Bilingual("直接控制（USB 直连）", "Direct control (USB)")
    @Volatile private var open = true
    private val reader = Thread({ readLoop() }, "cv-usb-in").apply { isDaemon = true; start() }

    override fun send(report: ByteArray, length: Int): Boolean {
        if (!open) return false
        val n = if (outEp != null) connection.bulkTransfer(outEp, report, length, 50)
        else connection.controlTransfer(0x21, 0x09, (2 shl 8) or (report[0].toInt() and 0xFF), intf.id, report, length, 50)
        return n >= 0
    }

    private fun readLoop() {
        val ep = inEp ?: return
        val buf = ByteArray(ep.maxPacketSize.coerceAtLeast(64))
        while (open) {
            val n = connection.bulkTransfer(ep, buf, buf.size, 200)
            if (n > 0) onInput(buf[0].toInt() and 0xFF, buf, n)
        }
    }

    override fun close() {
        open = false
        runCatching { reader.join(300) }
        runCatching { connection.releaseInterface(intf) }
        runCatching { connection.close() }
    }

    companion object {
        fun open(usb: UsbManager, device: UsbDevice): UsbDirectLink? {
            if (!usb.hasPermission(device)) return null
            val intf = (0 until device.interfaceCount).map { device.getInterface(it) }
                .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_HID } ?: return null
            val conn = usb.openDevice(device) ?: return null
            if (!conn.claimInterface(intf, true)) { conn.close(); return null }
            val eps = (0 until intf.endpointCount).map { intf.getEndpoint(it) }
            val outEp = eps.firstOrNull { it.direction == UsbConstants.USB_DIR_OUT && it.type == UsbConstants.USB_ENDPOINT_XFER_INT }
            val inEp = eps.firstOrNull { it.direction == UsbConstants.USB_DIR_IN && it.type == UsbConstants.USB_ENDPOINT_XFER_INT }
            Log.i("cv-engine", "USB direct: interface ${intf.id}, out=${outEp?.address}, in=${inEp?.address}")
            return UsbDirectLink(conn, intf, outEp, inEp)
        }
    }
}
