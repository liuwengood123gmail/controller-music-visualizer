package app.cmv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.cmv.engine.CaptureStatus
import app.cmv.engine.ControllerEngine
import app.cmv.engine.ControllerId
import app.cmv.engine.ControllerInfo
import app.cmv.engine.ControllerSettings
import app.cmv.engine.EngineState
import app.cmv.engine.Language
import app.cmv.engine.LatencyBreakdown
import app.cmv.engine.MassagePreset
import app.cmv.engine.Meter
import app.cmv.engine.MusicMode
import app.cmv.engine.SettingsPatch
import app.cmv.engine.Source
import kotlin.math.roundToInt

/**
 * 整个界面。engine 由 app 模块给出（真实引擎或假引擎），界面只认识 [ControllerEngine]。
 * debugMenu：app 模块往右上角菜单里加的调试项（例如切换假引擎剧本）
 * initialSelection：用户还没选手柄时默认选第几个（桌面版命令行 --select）
 */
@Composable
fun ControllerApp(
    engine: ControllerEngine,
    initialSelection: Int = 0,
    debugMenu: (@Composable ColumnScope.(close: () -> Unit) -> Unit)? = null,
) {
    val languagePrefs = rememberLanguagePrefs()
    var language by remember { mutableStateOf(languagePrefs.load()) }
    val state by engine.state.collectUiState()
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    val selected = state.controller(selectedId) ?: state.controllers.getOrNull(initialSelection)
        ?: state.controllers.firstOrNull()
    LaunchedEffect(selected?.id) { engine.focus(selected?.id) }

    CaptureConsentFlow(engine, state)
    PermissionEvents(engine)
    val startWithPermissions = rememberStartWithPermissions(engine)

    CompositionLocalProvider(LocalLanguage provides language) {
        MaterialTheme {
            Surface(Modifier.fillMaxSize()) {
                Column(Modifier.safeDrawingPadding().padding(horizontal = 16.dp, vertical = 12.dp)) {
                    Header(
                        state = state, selected = selected, language = language,
                        onSelect = { selectedId = it },
                        onLanguage = { language = it; languagePrefs.save(it) },
                        onToggle = { if (state.running) engine.stop() else startWithPermissions() },
                        debugMenu = debugMenu,
                    )
                    Spacer(Modifier.height(12.dp))
                    BoxWithConstraints(Modifier.fillMaxSize()) {
                        val wide = maxWidth >= 720.dp
                        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                            Messages(state)
                            if (selected != null) {
                                SessionPanel(engine, selected, state.running, wide)
                            } else {
                                EmptyHint()
                            }
                            Spacer(Modifier.height(24.dp))
                        }
                    }
                }
            }
        }
    }
}

// 授权流程（CaptureConsentFlow / PermissionEvents / rememberStartWithPermissions）在各平台的 Platform.kt 里

// MARK: - 顶部

@Composable
private fun Header(
    state: EngineState, selected: ControllerInfo?, language: Language,
    onSelect: (ControllerId) -> Unit, onLanguage: (Language) -> Unit, onToggle: () -> Unit,
    debugMenu: (@Composable ColumnScope.(close: () -> Unit) -> Unit)?,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("🎮", fontSize = 26.sp)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            ControllerChooser(state, selected, onSelect)
            Text(statusLine(state, selected), style = MaterialTheme.typography.bodySmall,
                 color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        SingleChoiceSegmentedButtonRow {
            Language.entries.forEachIndexed { i, l ->
                SegmentedButton(selected = language == l, onClick = { onLanguage(l) },
                                shape = SegmentedButtonDefaults.itemShape(i, Language.entries.size),
                                icon = {}) { Text(if (l == Language.ZH) "中" else "EN") }
            }
        }
        Spacer(Modifier.width(8.dp))
        Button(
            onClick = onToggle, enabled = state.running || state.canStart,
            colors = if (state.running) ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                     else ButtonDefaults.buttonColors(),
        ) { Text(if (state.running) L("停止", "Stop") else L("开始", "Start")) }
        if (debugMenu != null) {
            var open by remember { mutableStateOf(false) }
            Box {
                TextButton(onClick = { open = true }) { Text("⋮") }
                DropdownMenu(expanded = open, onDismissRequest = { open = false }) { debugMenu { open = false } }
            }
        }
    }
}

@Composable
private fun ControllerChooser(state: EngineState, selected: ControllerInfo?, onSelect: (ControllerId) -> Unit) {
    val language = LocalLanguage.current
    if (selected == null) {
        Text(L("未连接手柄", "No controller"), style = MaterialTheme.typography.titleMedium)
        return
    }
    val off = L("（未启用）", " (off)")
    fun label(c: ControllerInfo) = c.title(language) + if (c.settings.enabled) "" else off
    if (state.controllers.size > 1) {
        var open by remember { mutableStateOf(false) }
        Box {
            TextButton(onClick = { open = true }, contentPadding = ButtonDefaults.TextButtonContentPadding) {
                Text(label(selected) + "  ▾", style = MaterialTheme.typography.titleMedium)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                state.controllers.forEach { c ->
                    DropdownMenuItem(text = { Text(label(c)) }, onClick = { onSelect(c.id); open = false })
                }
            }
        }
    } else {
        Text(label(selected), style = MaterialTheme.typography.titleMedium)
    }
}

@Composable
private fun statusLine(state: EngineState, c: ControllerInfo?): String = when {
    c == null -> L("未运行", "Stopped")
    state.running -> if (c.status.isActive) c.status.engineName.text() else L("未启用", "Not enabled")
    !state.canStart && state.controllers.isNotEmpty() -> L("没有启用的手柄", "No controller enabled")
    else -> L("未运行", "Stopped")
}

@Composable
private fun Messages(state: EngineState) {
    val capture = state.capture
    val notice = state.notice?.text() ?: when (capture) {
        CaptureStatus.NeedsConsent -> L("请在弹出的对话框里允许录制屏幕（只用来读取正在播放的声音）",
                                       "Allow screen recording in the dialog (used only to read the audio being played)")
        CaptureStatus.Starting -> L("正在启动系统声音采集…", "Starting audio capture…")
        else -> null
    }
    if (notice != null) Banner(notice, MaterialTheme.colorScheme.tertiaryContainer)
    state.error?.let { Banner(it.text(), MaterialTheme.colorScheme.errorContainer) }
    val hint = captureRunningHint
    if (capture == CaptureStatus.Running && hint != null) {
        Text(hint.text(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
             modifier = Modifier.padding(bottom = 8.dp))
    }
}

@Composable
private fun Banner(text: String, color: Color) {
    Card(colors = CardDefaults.cardColors(containerColor = color), modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        Text(text, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun EmptyHint() {
    Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(L("没有找到手柄", "No controller found"), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))
        Text(L("用 USB 线或蓝牙连接 DualSense / 8BitDo 等手柄，连上后会自动出现在这里。",
               "Connect a DualSense, 8BitDo or other controller via USB or Bluetooth; it will appear here automatically."),
             textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium)
    }
}

// MARK: - 选中手柄的设置（D2：每个手柄各自一份）

@Composable
private fun SessionPanel(engine: ControllerEngine, info: ControllerInfo, running: Boolean, wide: Boolean) {
    val s = info.settings
    val update: (SettingsPatch) -> Unit = { engine.updateSettings(info.id, it) }
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(L("启用这个手柄", "Enable this controller"), Modifier.weight(1f))
            Switch(checked = s.enabled, onCheckedChange = { update(SettingsPatch(enabled = it)) })
        }
        info.access?.let { access ->
            Card(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Text(access.hint.text(), style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(8.dp))
                    OutlinedButton(onClick = { engine.requestDeviceAccess(info.id) }) { Text(L("授权", "Allow")) }
                }
            }
        }
        Column(Modifier.alpha(if (s.enabled) 1f else 0.5f)) {
            if (wide) {
                Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    Column(Modifier.weight(1f)) { SourcePanel(info, running, s.enabled, update) }
                    Column(Modifier.weight(1f)) {
                        FeaturesPanel(info, s.enabled, update)
                        MetersView(engine, info.id)
                    }
                }
            } else {
                SourcePanel(info, running, s.enabled, update)
                HorizontalDivider(Modifier.padding(vertical = 12.dp))
                FeaturesPanel(info, s.enabled, update)
                HorizontalDivider(Modifier.padding(vertical = 12.dp))
                MetersView(engine, info.id)
            }
        }
        info.status.error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it.text(), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun SourcePanel(info: ControllerInfo, running: Boolean, enabled: Boolean, update: (SettingsPatch) -> Unit) {
    val s = info.settings
    Segmented(Source.entries, s.source, enabled, { it.title.text() }) { update(SettingsPatch(source = it)) }
    Spacer(Modifier.height(12.dp))
    when (s.source) {
        Source.MUSIC -> MusicPanel(s, enabled, update)
        Source.MASSAGE -> MassagePanel(info, running, enabled, update)
    }
}

@Composable
private fun MusicPanel(s: ControllerSettings, enabled: Boolean, update: (SettingsPatch) -> Unit) {
    Segmented(MusicMode.entries, s.musicMode, enabled, { it.title.text() }) { update(SettingsPatch(musicMode = it)) }
    SettingSlider(L("强度", "Intensity"), s.intensity, 0f..3f, enabled) { update(SettingsPatch(intensity = it)) }
    SettingSlider(L("响应速度", "Response"), s.responsiveness, 0f..1f, enabled) { update(SettingsPatch(responsiveness = it)) }
    if (s.musicMode == MusicMode.BEAT) {
        SettingSlider(L("鼓点灵敏度", "Beat sensitivity"), s.sensitivity, 0f..1f, enabled) { update(SettingsPatch(sensitivity = it)) }
    }
    Caption(L("左声道 → 左马达，右声道 → 右马达。响应速度只影响震动。",
              "Left channel → left motor, right → right. Response only affects vibration."))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MassagePanel(info: ControllerInfo, running: Boolean, enabled: Boolean, update: (SettingsPatch) -> Unit) {
    val s = info.settings
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        MassagePreset.entries.forEach { p ->
            FilterChip(selected = s.preset == p, enabled = enabled, onClick = { update(SettingsPatch(preset = p)) },
                       label = { Text("${p.glyph} ${p.title.text()}") })
        }
    }
    val now = info.randomNow
    if (s.preset == MassagePreset.RANDOM && running && now != null) {
        Caption(L("随机轮播 · 正在播放：", "Random · now playing: ") + now.title.text())
    }
    SettingSlider(L("强度", "Intensity"), s.intensity, 0f..3f, enabled) { update(SettingsPatch(intensity = it)) }
    SettingSlider(L("速度", "Speed"), s.speed.toFloat(), 0.5f..2f, enabled, format = { "%.1f×".format(it) }) {
        update(SettingsPatch(speed = it.toDouble()))
    }
}

/** 按手柄能力隐藏不支持的设置项（D8） */
@Composable
private fun FeaturesPanel(info: ControllerInfo, enabled: Boolean, update: (SettingsPatch) -> Unit) {
    val s = info.settings
    val caps = info.capabilities
    if (caps.canVibrate) {
        Toggle(L("App 控制震动", "App controls vibration"), s.vibrationEnabled, enabled) { update(SettingsPatch(vibrationEnabled = it)) }
        if (s.vibrationEnabled && caps.hasHD) {
            Toggle(L("HD 震动（仅 USB，更细腻）", "HD haptics (USB only, finer detail)"), s.hdEnabled, enabled, indent = true) {
                update(SettingsPatch(hdEnabled = it))
            }
        }
    } else {
        Caption(L("这个手柄不支持震动。8BitDo 请切到 S 模式（Switch 模式）。", "This controller can't vibrate. For 8BitDo, switch to S mode."))
    }
    if (caps.hasAdaptiveTriggers) {
        Toggle(L("App 控制扳机（阻尼 · R2 加强 / L2 减弱）", "App controls triggers (resistance · R2 up / L2 down)"),
               s.triggersEnabled, enabled) { update(SettingsPatch(triggersEnabled = it)) }
        if (s.triggersEnabled) {
            SettingSlider(L("扳机阻尼", "Trigger resistance"), s.triggerResistance, 0f..1f, enabled, indent = true) {
                update(SettingsPatch(triggerResistance = it))
            }
        }
    } else {
        Toggle(L("App 控制 L2 / R2（R2 加强 / L2 减弱，App 在前台时）", "App controls L2 / R2 (R2 up / L2 down, while in foreground)"),
               s.triggersEnabled, enabled) { update(SettingsPatch(triggersEnabled = it)) }
    }
    if (caps.hasLight) {
        Toggle(if (s.source == Source.MUSIC) L("App 控制灯光（跟随音乐）", "App controls lights (follow music)")
               else L("App 控制灯光（按摩颜色）", "App controls lights (massage color)"),
               s.lightEffects, enabled) { update(SettingsPatch(lightEffects = it)) }
        if (s.lightEffects) {
            if (s.source == Source.MUSIC) {
                SettingSlider(L("灯条速度", "Light speed"), s.lightSpeed, 0f..1f, enabled, indent = true) { update(SettingsPatch(lightSpeed = it)) }
            }
            SettingSlider(L("灯条起伏", "Light range"), s.lightRange, 0f..1f, enabled, indent = true) { update(SettingsPatch(lightRange = it)) }
        }
    }
    if (caps.hasSpeaker) {
        Toggle(L("手柄扬声器同步播放（仅 USB）", "Play on controller speaker too (USB only)"), s.speakerEnabled, enabled) {
            update(SettingsPatch(speakerEnabled = it))
        }
        if (s.speakerEnabled) {
            SettingSlider(L("扬声器音量", "Speaker volume"), s.speakerVolume, 0f..1f, enabled, indent = true) {
                update(SettingsPatch(speakerVolume = it))
            }
            info.latency?.let { Caption(latencyText(it), indent = true) }
            info.audioStats?.let {
                Text(it, Modifier.padding(start = 20.dp), fontFamily = FontFamily.Monospace, fontSize = 11.sp,
                     color = MaterialTheme.colorScheme.outline)
            }
        }
    }
    Caption(L("取消勾选的项交给游戏控制，方便边玩游戏边用。", "Unchecked items are left to the game, so you can use this while gaming."))
}

@Composable
private fun latencyText(b: LatencyBreakdown): String {
    val parts = "%.0f + %.0f + %.0f ms".format(b.captureMs, b.marginMs, b.controllerOutputMs)
    val total = b.controllerTotalMs.roundToInt()
    return L("手柄扬声器延迟约 $total ms（采集 + 缓冲 + 手柄输出 = $parts）",
             "Controller speaker delay ~$total ms (capture + buffer + output = $parts)")
}

/** 只显示当前选中手柄的电平（D6）。单独订阅电平：约 30Hz 更新时只重组这两条 */
@Composable
private fun MetersView(engine: ControllerEngine, id: ControllerId) {
    val meters by engine.meters.collectUiState()
    val m = meters[id] ?: Meter.ZERO
    Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        MeterBar("L", m.left)
        MeterBar("R", m.right)
    }
}

@Composable
private fun MeterBar(label: String, v: Float) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontFamily = FontFamily.Monospace, fontSize = 12.sp, modifier = Modifier.width(16.dp))
        Box(Modifier.weight(1f).height(8.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(v.coerceIn(0f, 1f)).background(MaterialTheme.colorScheme.primary))
        }
    }
}

// MARK: - 小组件

@Composable
private fun <T> Segmented(items: List<T>, selected: T, enabled: Boolean, label: @Composable (T) -> String, onSelect: (T) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        items.forEachIndexed { i, item ->
            SegmentedButton(selected = item == selected, onClick = { onSelect(item) }, enabled = enabled,
                            shape = SegmentedButtonDefaults.itemShape(i, items.size), icon = {}) { Text(label(item)) }
        }
    }
}

@Composable
private fun Toggle(title: String, checked: Boolean, enabled: Boolean, indent: Boolean = false, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = if (indent) 20.dp else 0.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}

/**
 * 滑块：拖动时显示本地值，不被引擎回推覆盖（例如强度，L2/R2 也在改它）；松手后以引擎的值为准（§4.2 冲突规则）
 */
@Composable
private fun SettingSlider(
    title: String, value: Float, range: ClosedFloatingPointRange<Float>, enabled: Boolean, indent: Boolean = false,
    format: (Float) -> String = { "${(it * 100).roundToInt()}%" }, onChange: (Float) -> Unit,
) {
    var dragging by remember { mutableStateOf<Float?>(null) }
    val shown = dragging ?: value
    Row(Modifier.fillMaxWidth().padding(start = if (indent) 20.dp else 0.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.width(if (LocalLanguage.current == Language.ZH) 84.dp else 120.dp), style = MaterialTheme.typography.bodyMedium)
        Slider(value = shown, onValueChange = { dragging = it; onChange(it) }, onValueChangeFinished = { dragging = null },
               valueRange = range, enabled = enabled, modifier = Modifier.weight(1f))
        Text(format(shown), Modifier.width(48.dp), textAlign = TextAlign.End, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun Caption(text: String, indent: Boolean = false) {
    Text(text, Modifier.padding(start = if (indent) 20.dp else 0.dp, top = 4.dp, bottom = 4.dp),
         style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

