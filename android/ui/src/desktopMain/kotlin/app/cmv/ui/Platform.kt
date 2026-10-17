package app.cmv.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import app.cmv.engine.Bilingual
import app.cmv.engine.ControllerEngine
import app.cmv.engine.EngineState
import app.cmv.engine.Language
import java.util.prefs.Preferences
import kotlinx.coroutines.flow.StateFlow

// 桌面（Windows）平台部分。Android 版的同名函数在 androidMain/Platform.kt，两边签名保持一致。

@Composable
internal fun <T> StateFlow<T>.collectUiState(): State<T> = collectAsState()

/** WASAPI 环回拿到的是整个系统混音，没有「某些 App 禁止录制」的限制 */
internal val captureRunningHint: Bilingual? = null

@Composable
internal fun rememberLanguagePrefs(): LanguagePrefs = remember {
    object : LanguagePrefs {
        private val prefs = Preferences.userRoot().node("app/cmv/ui")
        override fun loadSaved(): String? = prefs.get("language", null)
        override fun save(language: Language) = prefs.put("language", language.name)
    }
}

/** WASAPI 环回不需要授权，CaptureStatus.NeedsConsent 不会出现 */
@Composable
internal fun CaptureConsentFlow(engine: ControllerEngine, state: EngineState) {}

/** 桌面版没有运行时权限 */
@Composable
internal fun PermissionEvents(engine: ControllerEngine) {}

@Composable
internal fun rememberStartWithPermissions(engine: ControllerEngine): () -> Unit = remember(engine) { { engine.start() } }
