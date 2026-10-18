package app.cmv.engine.windows

import app.cmv.engine.ControllerSettings
import app.cmv.engine.MassagePreset
import app.cmv.engine.Source
import java.io.File
import kotlin.math.abs
import kotlin.math.sin
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * 把每一个 JNI 函数调一遍（对应 Android 的 NativeCoreTest）：验证 cvwin.dll / ControllerCAPI.dll / Swift 运行库能从
 * 同一目录加载、JNI 签名与 C 层一致、Swift 核心算得对。没有构建 native-win（例如非 Windows）时跳过。
 */
class NativeCoreTest {
    @Before fun nativeBuilt() {
        val dir = System.getProperty("cv.native.dir")
        assumeTrue("native-win not built", System.getProperty("os.name").startsWith("Windows") &&
            dir != null && File(dir, "cvwin.dll").isFile)
    }

    @Test fun version() = assertEquals(1, NativeCore.apiVersion())

    @Test fun sessionTickMassage() {
        val core = NativeCore.coreCreate(200f)
        val s = NativeCore.sessionCreate()
        assertEquals(0, NativeCore.sessionSetSettings(s, ControllerSettings(source = Source.MASSAGE, preset = MassagePreset.POUND).toJson()))
        val out = FloatArray(NativeCore.TICK_COUNT)
        var peak = 0f
        val flags = NativeCore.F_VIBRATION or NativeCore.F_TRIGGERS or NativeCore.F_LIGHTS or NativeCore.F_ADAPTIVE_TRIGGERS or NativeCore.F_PLAYER_LEDS
        repeat(300) { i ->
            NativeCore.sessionTick(s, core, flags, 0f, if (i < 100) 1f else 0f, 0.01f, 0.0, out)
            peak = maxOf(peak, out[NativeCore.T_MOTOR_L])
            assertEquals(0.5f, out[NativeCore.T_RESISTANCE])
            assertEquals(1f, out[NativeCore.T_LIGHT])
        }
        assertTrue(peak > 0.3f)
        NativeCore.sessionReset(s)
        NativeCore.sessionTick(s, core, NativeCore.F_VIBRATION or NativeCore.F_HD_ACTIVE, 0f, 0f, 0.01f, 0.0, out)
        assertEquals(1f, out[NativeCore.T_HD])
        NativeCore.sessionDestroy(s)
        NativeCore.coreDestroy(core)
    }

    @Test fun dualSenseReports() {
        val h = NativeCore.dsCreate(false)
        val buf = ByteArray(128)
        NativeCore.dsSetControls(h, true, true, true)
        NativeCore.dsSend(h)
        assertEquals(48, NativeCore.dsTakeReport(h, buf))
        assertEquals(0x02, buf[0].toInt())
        NativeCore.dsSetLight(h, 1f, 0f, 0f)
        NativeCore.dsSetTriggerResistance(h, 1f)
        NativeCore.dsSetPlayerLeds(h, 0x1F)
        NativeCore.dsSetHd(h, true)
        NativeCore.dsSetSpeaker(h, true, 0x64, 2)
        while (NativeCore.dsTakeReport(h, buf) > 0) Unit
        NativeCore.dsSetMotors(h, 1f, 0f)
        NativeCore.dsStop(h)
        assertTrue(NativeCore.dsTakeReport(h, buf) > 0)
        NativeCore.dsDestroy(h)

        val bt = NativeCore.dsCreate(true)
        NativeCore.dsSend(bt)
        assertEquals(78, NativeCore.dsTakeReport(bt, buf))
        assertEquals(0x31, buf[0].toInt())
        NativeCore.dsDestroy(bt)

        val input = ByteArray(64).also { it[0] = 1; it[5] = 255.toByte(); it[6] = 128.toByte() }
        val parsed = FloatArray(4)
        assertTrue(NativeCore.dsParseInput(1, input, 64, parsed))
        assertTrue(abs(parsed[0] - 1f) < 0.01f)
    }

    @Test fun rendererAndCorePath() {
        val core = NativeCore.coreCreate(200f)
        val r = NativeCore.rendererCreate(core, 48000f, true, Double.NaN, Double.NaN)
        NativeCore.rendererSet(r, 1f, 0f, 100f, false)
        NativeCore.rendererSetSpeakerVolume(r, 0.5f)
        assertTrue(NativeCore.rendererSpeakerAudible(r))
        val chunk = FloatArray(512)
        var t = 0
        repeat(50) {
            for (i in 0 until 256) { val v = (sin(2 * Math.PI * 440 * (t + i) / 48000) * 0.5).toFloat(); chunk[2 * i] = v; chunk[2 * i + 1] = v }
            t += 256
            NativeCore.coreProcess(core, chunk, 256, 48000f)
        }
        val stats = DoubleArray(2)
        NativeCore.rendererStats(r, stats)
        NativeCore.rendererMute(r)
        NativeCore.rendererDestroy(r)
        NativeCore.coreReset(core)
        NativeCore.coreDestroy(core)
    }

    @Test fun jsonHelpers() {
        val initial = ControllerSettings.fromJson(NativeCore.settingsInitial(null, ControllerSettings(enabled = false, intensity = 2f).toJson()))
        assertEquals(ControllerSettings(intensity = 2f), initial)
        val patched = NativeCore.settingsApplyPatch(ControllerSettings().toJson(), """{"intensity":9}""")
        assertEquals(3f, ControllerSettings.fromJson(patched).intensity)
        val plan = NativeCore.reconcile("""{"existing":[{"kind":"dualSense","key":"a"}],"found":[{"kind":"dualSense","key":"b"}]}""")
        assertTrue(plan.contains("migrate"), plan)
        assertNotEquals(0.0, NativeCore.alignDelayMs(true, false, 8.0, 4.0, Double.NaN))
    }

    /** 采集能启停；有默认输出设备的机器上会进入运行状态（CI 的 runner 可能没有声卡，只要求启停不崩、不卡） */
    @Test fun captureLifecycle() {
        val core = NativeCore.coreCreate(200f)
        NativeCore.highResTimer(true)
        val h = NativeCore.captureStart(core)
        assertNotEquals(0L, h)
        val state = IntArray(5)
        var tries = 0
        do { Thread.sleep(20); NativeCore.captureState(h, state) } while (state[0] == 0 && ++tries < 50)
        if (state[0] == 1) {
            assertTrue(state[1] > 0, "sample rate")
            assertTrue(state[2] > 0, "channels")
        }
        NativeCore.captureStop(h)
        NativeCore.highResTimer(false)
        NativeCore.coreDestroy(core)
    }
}
