package app.cmv.engine.android

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.util.Log

/**
 * 系统声音采集（Android 10+ AudioPlaybackCapture）：只能采到用途为媒体 / 游戏 / 未知、且允许被采集的 App。
 * 读线程把 48kHz float 立体声块交给 Swift 核心（分析器 + 扬声器缓冲，与 macOS 采集回调相同）。
 */
class PlaybackCapture(private val projection: MediaProjection, private val core: Long, private val onError: (String) -> Unit) {
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    /** 估算的采集延迟（ms）：一次读取的块 + AudioRecord 内部缓冲的一半 */
    var latencyMs = 0.0; private set

    @SuppressLint("MissingPermission")   // RECORD_AUDIO 由界面在开始前申请；没有时这里抛异常，按采集失败处理
    fun start() {
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO).build()
        val min = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
        val bufferBytes = maxOf(min, CHUNK * 2 * 4 * 4)
        val r = AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(bufferBytes)
            .setAudioPlaybackCaptureConfig(config).build()
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); throw IllegalStateException("AudioRecord not initialized") }
        latencyMs = CHUNK * 1000.0 / SAMPLE_RATE + bufferBytes / 8.0 * 1000.0 / SAMPLE_RATE / 2
        record = r
        running = true
        r.startRecording()
        thread = Thread({ loop(r) }, "cv-capture").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    private fun loop(r: AudioRecord) {
        val buf = FloatArray(CHUNK * 2)
        while (running) {
            val n = r.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
            if (n < 0) { Log.w("cv-engine", "capture read error $n"); onError("read error $n"); break }
            if (n >= 2) NativeCore.coreProcess(core, buf, n / 2, SAMPLE_RATE.toFloat())
        }
    }

    fun stop() {
        running = false
        runCatching { record?.stop() }
        runCatching { thread?.join(500) }
        runCatching { record?.release() }
        record = null
    }

    companion object {
        const val SAMPLE_RATE = 48000
        /** 每次读取 256 帧（约 5.3ms） */
        const val CHUNK = 256
    }
}
