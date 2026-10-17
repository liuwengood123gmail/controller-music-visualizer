package app.cmv.engine.android

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.util.Log

/**
 * C 档：USB DualSense 的 4 声道音频输出（第 1/2 声道 = 扬声器，第 3/4 声道 = HD 震动）。
 * AAudio 流在 C 层（cv_jni.c），实时回调直接调用 Swift 的 ControllerAudioRenderer。
 */
class ControllerAudio private constructor(
    private val renderer: Long,
    private val stream: Long,
    val sampleRate: Int,
    val bufferFrames: Int,
    val burstFrames: Int,
) {
    private val stats = DoubleArray(2)
    private val state = IntArray(3)

    fun set(l: Float, r: Float, freq: Float, useMusic: Boolean) = NativeCore.rendererSet(renderer, l, r, freq, useMusic)
    fun setSpeakerVolume(v: Float) = NativeCore.rendererSetSpeakerVolume(renderer, v)

    /** 当前缓冲余量（ms）和欠载次数 */
    fun marginMs(): Double { NativeCore.rendererStats(renderer, stats); return stats[0] }
    fun underruns(): Int { NativeCore.rendererStats(renderer, stats); return stats[1].toInt() }

    /** AAudio 的输出延迟估算：设备缓冲 */
    val outputMs: Double get() = if (sampleRate > 0) bufferFrames * 1000.0 / sampleRate else 0.0

    val disconnected: Boolean get() { NativeCore.audioState(stream, state); return state[0] != 0 }
    val xruns: Int get() { NativeCore.audioState(stream, state); return state[1] }

    fun stop() {
        // 扬声器先淡出再停，避免咔哒声
        if (NativeCore.rendererSpeakerAudible(renderer)) {
            NativeCore.rendererMute(renderer)
            Thread.sleep(25)
        }
        NativeCore.audioClose(stream)
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
    }
}
