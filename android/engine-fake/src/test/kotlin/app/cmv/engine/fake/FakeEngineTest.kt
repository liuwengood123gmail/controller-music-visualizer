package app.cmv.engine.fake

import app.cmv.engine.CaptureConsent
import app.cmv.engine.CaptureStatus
import app.cmv.engine.SettingsPatch
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FakeEngineTest {
    @Test fun startNeedsConsentThenRuns() {
        val e = FakeControllerEngine(FakeControllerEngine.Scenario.MULTI)
        assertTrue(e.state.value.canStart)
        e.start()
        assertTrue(e.state.value.running)
        assertEquals(CaptureStatus.NeedsConsent, e.state.value.capture)
        e.provideCaptureConsent(CaptureConsent(granted = true))
        assertEquals(CaptureStatus.Running, e.state.value.capture)
        assertTrue(e.state.value.controllers.all { it.status.isActive })
        e.advance(0.033)
        assertEquals(3, e.meters.value.size)
        e.stop()
        assertTrue(e.meters.value.isEmpty())
        assertFalse(e.state.value.controllers.any { it.status.isActive })
    }

    @Test fun captureDenied() {
        val e = FakeControllerEngine(FakeControllerEngine.Scenario.CAPTURE_DENIED)
        e.start()
        e.provideCaptureConsent(CaptureConsent(granted = true))
        assertIs<CaptureStatus.Failed>(e.state.value.capture)
        assertNotNull(e.state.value.error)
    }

    @Test fun patchOnlyChangesGivenFields() {
        val e = FakeControllerEngine(FakeControllerEngine.Scenario.SINGLE_USB)
        e.updateSettings(FakeControllerEngine.USB_ID, SettingsPatch(intensity = 9f))
        val s = e.state.value.controller(FakeControllerEngine.USB_ID)!!.settings
        assertEquals(3f, s.intensity)
        assertTrue(s.vibrationEnabled)
    }

    @Test fun deviceAccessUnlocksCapabilities() {
        val e = FakeControllerEngine(FakeControllerEngine.Scenario.SINGLE_USB)
        val before = e.state.value.controller(FakeControllerEngine.USB_ID)!!
        assertNotNull(before.access); assertFalse(before.capabilities.hasSpeaker)
        e.requestDeviceAccess(FakeControllerEngine.USB_ID)
        val after = e.state.value.controller(FakeControllerEngine.USB_ID)!!
        assertNull(after.access); assertTrue(after.capabilities.hasSpeaker)
    }

    @Test fun unplugScenario() {
        val e = FakeControllerEngine(FakeControllerEngine.Scenario.UNPLUG)
        e.start()
        repeat(200) { e.advance(0.033) }
        assertEquals(2, e.state.value.controllers.size)
    }

    @Test fun noControllers() {
        val e = FakeControllerEngine(FakeControllerEngine.Scenario.NONE)
        e.start()
        assertFalse(e.state.value.running)
        assertNotNull(e.state.value.error)
    }
}
