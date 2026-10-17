package app.cmv.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.cmv.engine.Bilingual
import app.cmv.engine.CaptureConsent
import app.cmv.engine.CaptureStatus
import app.cmv.engine.ControllerEngine
import app.cmv.engine.ControllerId
import app.cmv.engine.EngineEvent
import app.cmv.engine.EngineState
import app.cmv.engine.Language
import kotlinx.coroutines.flow.StateFlow

// Android 平台部分。桌面版的同名函数在 desktopMain/Platform.kt，两边签名保持一致。

@Composable
internal fun <T> StateFlow<T>.collectUiState(): State<T> = collectAsStateWithLifecycle()

internal val captureRunningHint: Bilingual? = Bilingual(
    "只能读到允许被录制的 App 的声音；某个 App 没反应时，它可能禁止了录制。",
    "Only apps that allow capture can be heard; if an app has no effect, it may block capture.",
)

@Composable
internal fun rememberLanguagePrefs(): LanguagePrefs {
    val context = LocalContext.current.applicationContext
    return remember(context) {
        object : LanguagePrefs {
            private val prefs = context.getSharedPreferences("ui", Context.MODE_PRIVATE)
            override fun loadSaved(): String? = prefs.getString("language", null)
            override fun save(language: Language) { prefs.edit().putString("language", language.name).apply() }
        }
    }
}

/** 引擎要求采集授权时弹出系统的屏幕录制对话框 */
@Composable
internal fun CaptureConsentFlow(engine: ControllerEngine, state: EngineState) {
    val context = LocalContext.current
    var inFlight by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        inFlight = false
        engine.provideCaptureConsent(CaptureConsent(r.resultCode == Activity.RESULT_OK, r.resultCode, r.data))
    }
    LaunchedEffect(state.capture) {
        if (state.capture == CaptureStatus.NeedsConsent && !inFlight) {
            inFlight = true
            val mpm = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            runCatching { launcher.launch(mpm.createScreenCaptureIntent()) }.onFailure {
                inFlight = false
                engine.provideCaptureConsent(CaptureConsent(false))
            }
        }
    }
}

/** 引擎需要运行时权限（例如 Android 17 的 HID 访问）时申请，拿到后再请求一次设备访问 */
@Composable
internal fun PermissionEvents(engine: ControllerEngine) {
    var pending by remember { mutableStateOf<ControllerId?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val id = pending
        pending = null
        if (granted && id != null) engine.requestDeviceAccess(id)
    }
    LaunchedEffect(engine) {
        engine.events.collect { e ->
            if (e is EngineEvent.NeedsPermission) {
                pending = e.id
                launcher.launch(e.permission)
            }
        }
    }
}

/** 开始前申请「录音」（播放采集需要）和通知（前台服务的常驻通知）权限；拒绝也照样开始（按摩不需要录音） */
@Composable
internal fun rememberStartWithPermissions(engine: ControllerEngine): () -> Unit {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        engine.start()
    }
    return remember(engine) {
        {
            val wanted = buildList {
                add(Manifest.permission.RECORD_AUDIO)
                if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            }
            launcher.launch(wanted.toTypedArray())
        }
    }
}
