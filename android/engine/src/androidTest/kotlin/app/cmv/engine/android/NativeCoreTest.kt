package app.cmv.engine.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.cmv.engine.ControllerSettings
import app.cmv.engine.MassagePreset
import app.cmv.engine.Source
import kotlin.math.abs
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 在真机 / 模拟器上调用每一个 JNI 函数：验证 .so 能加载（Swift 运行库齐全）、JNI 签名与 C 层一致、Swift 核心算得对。
 * CI 在 x86_64 模拟器上跑（.github/workflows/build.yml 的 android-emulator）。
 */
@RunWith(AndroidJUnit4::class)
class NativeCoreTest {
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
            assertTrue(out[NativeCore.T_LEDS] >= 0)
        }
        assertTrue(peak > 0.3f)
        NativeCore.sessionReset(s)
        NativeCore.sessionTick(s, core, NativeCore.F_VIBRATION or NativeCore.F_HD_ACTIVE, 0f, 0f, 0.01f, 0.0, out)
        assertEquals(1f, out[NativeCore.T_HD])
        assertEquals(0f, out[NativeCore.T_MOTOR_L])
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

    @Test fun rendererAndCapturePath() {
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

    /** USB 直接输出：模拟器上没有手柄，用管道代替 usbdevfs 句柄——提交失败要报告「已断开」，关闭不能卡住 */
    @Test fun usbAudioLifecycle() {
        val core = NativeCore.coreCreate(200f)
        val r = NativeCore.rendererCreate(core, 48000f, true, Double.NaN, Double.NaN)
        val info = IntArray(4)
        // 每包 384 字节 > 端点 200 字节：拒绝
        assertEquals(0L, NativeCore.usbAudioOpen(r, -1, 0x01, 200, 48000, 4, 3, info))
        val pipe = android.os.ParcelFileDescriptor.createPipe()
        val h = NativeCore.usbAudioOpen(r, pipe[1].fd, 0x01, 392, 48000, 4, 3, info)
        assertNotEquals(0L, h)
        assertEquals(listOf(4, 48000, 576, 144), info.toList())
        val state = IntArray(3)
        var tries = 0
        do { Thread.sleep(10); NativeCore.usbAudioState(h, state) } while (state[0] == 0 && ++tries < 100)
        assertEquals(1, state[0])
        NativeCore.usbAudioClose(h)
        pipe.forEach { it.close() }
        NativeCore.rendererDestroy(r)
        NativeCore.coreDestroy(core)
    }

    @Test fun jsonHelpers() {
        val initial = ControllerSettings.fromJson(NativeCore.settingsInitial(null, ControllerSettings(enabled = false, intensity = 2f).toJson()))
        assertEquals(ControllerSettings(intensity = 2f), initial)
        val patched = NativeCore.settingsApplyPatch(ControllerSettings().toJson(), """{"intensity":9}""")
        assertEquals(3f, ControllerSettings.fromJson(patched).intensity)
        val plan = NativeCore.reconcile("""{"existing":[{"kind":"dualSense","key":"a"}],"found":[{"kind":"dualSense","key":"b"}]}""")
        assertTrue(plan, plan.contains("migrate"))
        assertNotEquals(0.0, NativeCore.alignDelayMs(true, false, 8.0, 4.0, Double.NaN), 0.0)
    }

    /** 引擎能在设备上起来（没有手柄时状态为空、不能开始） */
    @Test fun engineStartsWithoutControllers() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val e = AndroidControllerEngine.get(ctx)
        Thread.sleep(500)
        assertTrue(e.state.value.controllers.isEmpty() || e.state.value.controllers.all { it.name.isNotEmpty() })
    }
}
