package app.cmv.engine

import java.io.File
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** contract/fixtures：与 Swift 端的 ContractTests 读同一组文件 */
class ContractTest {
    private val dir = File(System.getProperty("contract.dir") ?: "../../contract/fixtures")

    private fun load(name: String) = Json.parseToJsonElement(File(dir, name).readText()).jsonObject

    private fun assertSame(expected: JsonObject, actual: JsonObject, label: String) {
        assertEquals(expected.keys, actual.keys, label)
        for ((k, e) in expected) {
            val a = actual[k]!!.jsonPrimitive
            val ep = e.jsonPrimitive
            if (!ep.isString && ep.doubleOrNull != null && ep.content != "true" && ep.content != "false") {
                assertTrue(abs(ep.doubleOrNull!! - a.doubleOrNull!!) < 1e-6, "$label.$k: $ep vs $a")
            } else {
                assertEquals(ep.content, a.content, "$label.$k")
            }
        }
    }

    @Test fun settingsFixtures() {
        for (name in listOf("settings-default.json", "settings-old-version.json", "settings-out-of-range.json")) {
            val f = load(name)
            val s = ControllerSettings.fromJson(f["input"]!!.jsonObject)
            assertSame(f["expected"]!!.jsonObject, s.toJsonObject(), name)
            // 编码后再解码不变
            assertEquals(s, ControllerSettings.fromJson(s.toJson()), name)
        }
    }

    @Test fun patchFixture() {
        val f = load("settings-patch.json")
        val s = ControllerSettings.fromJson(f["settings"]!!.jsonObject)
        val p = SettingsPatch.fromJson(f["patch"]!!.jsonObject)
        assertSame(f["expected"]!!.jsonObject, p.apply(s).toJsonObject(), "patch")
    }

    @Test fun enumsFixture() {
        val f = load("enums.json")
        fun list(k: String) = f[k]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(list("source"), Source.entries.map { it.json })
        assertEquals(list("musicMode"), MusicMode.entries.map { it.json })
        assertEquals(list("preset"), MassagePreset.entries.map { it.json })
    }

    @Test fun diffAndApplyRoundTrip() {
        val a = ControllerSettings()
        val b = a.copy(intensity = 2f, preset = MassagePreset.GUN, speakerEnabled = true)
        val p = SettingsPatch.diff(a, b)
        assertEquals(SettingsPatch(intensity = 2f, preset = MassagePreset.GUN, speakerEnabled = true), p)
        assertEquals(b, p.apply(a))
        assertTrue(SettingsPatch.diff(a, a).isEmpty)
    }

    @Test fun initialCopiesSelected() {
        val sel = ControllerSettings(enabled = false, intensity = 2f)
        assertEquals(sel.copy(enabled = true), ControllerSettings.initial(null, sel))
        assertEquals(ControllerSettings(), ControllerSettings.initial(null, null))
        assertEquals(sel, ControllerSettings.initial(sel, null))
    }

}
