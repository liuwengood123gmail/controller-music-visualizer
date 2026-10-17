package app.cmv.engine.android

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.util.Log

/**
 * C 档：USB DualSense 的 4 声道音频输出（第 1/2 声道 = 扬声器，第 3/4 声道 = HD 震动）。两种方式：
 * - AAudio：系统把手柄登记成音频输出时（流在 cv_jni.c，实时回调直接调用 Swift 的 ControllerAudioRenderer）；
 * - USB 直接输出：系统没把手柄登记成输出时（实测 Android 15 上 hasOutput: false），在 USB 直连上自己发等时传输（usb_audio.c）。
 */
class ControllerAudio private constructor(
    private val renderer: Long,
    private val stream: Long,
    val sampleRate: Int,
    val bufferFrames: Int,
    val burstFrames: Int,
    /** USB 直接输出时占用的接口（AAudio 时为 null） */
    private val usb: UsbAudioPort? = null,
) {
    /** 调试行里显示的输出方式 */
    val backend: String get() = if (usb != null) "USB direct" else "AAudio"
    private val stats = DoubleArray(2)
    private val state = IntArray(3)

    fun set(l: Float, r: Float, freq: Float, useMusic: Boolean) = NativeCore.rendererSet(renderer, l, r, freq, useMusic)
    fun setSpeakerVolume(v: Float) = NativeCore.rendererSetSpeakerVolume(renderer, v)

    /** 当前缓冲余量（ms）和欠载次数 */
    fun marginMs(): Double { NativeCore.rendererStats(renderer, stats); return stats[0] }
    fun underruns(): Int { NativeCore.rendererStats(renderer, stats); return stats[1].toInt() }

    /** AAudio 的输出延迟估算：设备缓冲 */
    val outputMs: Double get() = if (sampleRate > 0) bufferFrames * 1000.0 / sampleRate else 0.0

    private fun readState() = if (usb != null) NativeCore.usbAudioState(stream, state) else NativeCore.audioState(stream, state)
    val disconnected: Boolean get() { readState(); return state[0] != 0 }
    /** AAudio：欠载次数；USB 直接输出：等时调度出现空档的次数 */
    val xruns: Int get() { readState(); return state[1] }

    fun stop() {
        // 扬声器先淡出再停，避免咔哒声
        if (NativeCore.rendererSpeakerAudible(renderer)) {
            NativeCore.rendererMute(renderer)
            Thread.sleep(25)
        }
        if (usb != null) { NativeCore.usbAudioClose(stream); usb.release() } else NativeCore.audioClose(stream)
        NativeCore.rendererDestroy(renderer)
    }

    companion object {
        /** 手柄的 USB 音频输出设备（产品名带 Wireless Controller / DualSense） */
        fun findDevice(context: Context): AudioDeviceInfo? {
            val am = context.getSystemService(AudioManager::class.java)
            return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { d ->
                (d.type == AudioDeviceInfo.TYPE_USB_DEVICE || d.type == AudioDeviceInfo.TYPE_USB_HEADSET) &&
                    (d.productName?.toString() ?: "").let { it.contains("Wireless Controller", true) || it.contains("DualSense", true) }
            }
        }

        /** 打开失败（找不到设备、不是 4 声道）返回 null，reason 给出原因 */
        fun open(context: Context, core: Long, haptics: Boolean, reason: (String) -> Unit): ControllerAudio? {
            val dev = findDevice(context) ?: run { reason("no USB audio device for the controller"); return null }
            val channels = dev.channelCounts.joinToString()
            // 应用这一侧总能打开 4 声道（系统会混音到设备的实际声道数），所以先看设备自己报告的声道数
            if (dev.channelCounts.isNotEmpty() && dev.channelCounts.max() < 4) {
                reason("device reports channels [$channels], need 4"); return null
            }
            val sr = dev.sampleRates.takeIf { it.isNotEmpty() }?.let { if (48000 in it) 48000 else it.max() } ?: 48000
            val renderer = NativeCore.rendererCreate(core, sr.toFloat(), haptics, Double.NaN, Double.NaN)
            val info = IntArray(4)
            val stream = NativeCore.audioOpen(renderer, dev.id, sr, info)
            Log.i("cv-engine", "controller audio ${dev.productName}: channels [$channels], opened ${info.joinToString()}")
            if (stream == 0L) {
                NativeCore.rendererDestroy(renderer)
                reason(if (info[0] in 1..3) "device opened with ${info[0]} channels (need 4)" else "AAudio open failed")
                return null
            }
            return ControllerAudio(renderer, stream, info[1], info[2], info[3])
        }

        /** USB 直接输出排队的 URB 个数 × 每个 URB 的毫秒数（= 输出缓冲 12ms） */
        const val USB_URBS = 4
        const val USB_PACKETS = 3

        /** 在 USB 直连上直接输出（DualSense 只有 48kHz）。失败返回 null，reason 给出原因 */
        fun openUsb(core: Long, haptics: Boolean, link: UsbDirectLink, reason: (String) -> Unit): ControllerAudio? {
            val sr = 48000
            val port = link.openAudio(reason) ?: return null
            val renderer = NativeCore.rendererCreate(core, sr.toFloat(), haptics, Double.NaN, Double.NaN)
            val info = IntArray(4)
            val stream = NativeCore.usbAudioOpen(renderer, port.fd, port.endpoint, port.maxPacket, sr, USB_URBS, USB_PACKETS, info)
            if (stream == 0L) {
                NativeCore.rendererDestroy(renderer)
                port.release()
                reason("USB isochronous output failed to start (max packet ${port.maxPacket})")
                return null
            }
            Log.i("cv-engine", "controller audio: USB direct, ${info.joinToString()}")
            return ControllerAudio(renderer, stream, info[1], info[2], info[3], port)
        }
    }
}
