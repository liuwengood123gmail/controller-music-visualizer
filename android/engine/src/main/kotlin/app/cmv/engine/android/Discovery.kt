package app.cmv.engine.android

import android.content.Context
import android.hardware.input.InputManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.view.InputDevice

/** 手柄身份（与 Swift 的 ControllerIdentity 同构：kind + key，key 用来记住设置） */
data class Identity(val kind: String, val key: String) {
    val isDualSense get() = kind == "dualSense"
}

/** 发现到的一台手柄 */
data class Found(
    val identity: Identity,
    val name: String,
    /** 系统输入设备（A 档：震动 / 灯 / 扳机轴 / 电量）；USB 直连时内核驱动被断开，这里会是 null */
    val inputDeviceId: Int?,
    /** USB 连接的 DualSense */
    val usb: UsbDevice?,
    val bluetooth: Boolean,
)

/**
 * 发现手柄：
 * - USB 的 DualSense 以 UsbManager 为准（USB 直连时系统输入设备会消失，但 USB 设备还在），身份 = 序号；
 * - 其余的 DualSense（InputDevice，厂商 0x054C）视为蓝牙，身份 = 设备描述符；
 * - 其他手柄：身份 = InputDevice 描述符（跨重启稳定）。
 */
class Discovery(private val context: Context) {
    private val input = context.getSystemService(InputManager::class.java)
    private val usb = context.getSystemService(UsbManager::class.java)

    fun discover(): List<Found> {
        val usbDualSenses = usb.deviceList.values.filter { isDualSense(it.vendorId, it.productId) }.sortedBy { it.deviceName }
        val inputs = input.inputDeviceIds.toList().mapNotNull { InputDevice.getDevice(it) }.filter { isGamepad(it) }
        val sonyInputs = inputs.filter { isDualSense(it.vendorId, it.productId) }
        val others = inputs.filter { !isDualSense(it.vendorId, it.productId) }

        // 哪些 Sony 输入设备是 USB：内核 hid-playstation 用 HID 设备名命名，USB 时是「厂商 + 产品」
        //（Sony Interactive Entertainment DualSense …），蓝牙时是蓝牙设备名（DualSense Wireless Controller）。
        // 名字分不出来时按数量推断（前 N 个对应 USB）
        val byName = sonyInputs.partition { it.name.orEmpty().startsWith("Sony", ignoreCase = true) }
        val (usbInputs, btInputs) = if (byName.first.size == usbDualSenses.size) byName
            else sonyInputs.sortedBy { it.id }.let { it.take(usbDualSenses.size) to it.drop(usbDualSenses.size) }

        val found = mutableListOf<Found>()
        usbDualSenses.forEachIndexed { i, d ->
            found += Found(Identity("dualSense", "ds:usb:$i"), "DualSense", usbInputs.getOrNull(i)?.id, d, bluetooth = false)
        }
        btInputs.forEach { d ->
            found += Found(Identity("dualSense", "ds:bt:${d.descriptor}"), "DualSense", d.id, null, bluetooth = true)
        }
        others.forEach { d ->
            found += Found(Identity("gamepad", "gp:${d.descriptor}"), d.name ?: "Controller", d.id, null, bluetooth = false)
        }
        return found
    }

    companion object {
        const val SONY = 0x054C
        fun isDualSense(vendor: Int, product: Int) = vendor == SONY && (product == 0x0CE6 || product == 0x0DF2)

        fun isGamepad(d: InputDevice): Boolean {
            if (d.isVirtual) return false
            val s = d.sources
            return (s and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD ||
                (s and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK
        }
    }
}
