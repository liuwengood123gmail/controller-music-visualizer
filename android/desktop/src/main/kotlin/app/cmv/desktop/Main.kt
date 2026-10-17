package app.cmv.desktop

import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Notification
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.rememberTrayState
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import app.cmv.engine.ControllerEngine
import app.cmv.engine.SettingsPatch
import app.cmv.engine.Source
import app.cmv.engine.fake.FakeControllerEngine
import app.cmv.ui.ControllerApp
import app.cmv.ui.L
import app.cmv.ui.text
import java.util.Locale
import java.util.prefs.Preferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first

private const val REAL = "real"

/** 命令行参数（与 macOS 版相同）：--fake-engine [剧本]、--autostart、--massage、--select <n> */
private class Options(args: Array<String>) {
    var fakeScenario: String? = null
    var autostart = false
    var massage = false
    var select = 0

    init {
        var i = 0
        while (i < args.size) {
            when (args[i]) {
                "--fake-engine" -> {
                    val next = args.getOrNull(i + 1)
                    val scenario = FakeControllerEngine.Scenario.entries.firstOrNull { it.name.equals(next, ignoreCase = true) }
                    if (scenario != null) i++
                    fakeScenario = (scenario ?: FakeControllerEngine.Scenario.MULTI).name
                }
                "--autostart" -> autostart = true
                "--massage" -> massage = true
                "--select" -> { select = args.getOrNull(i + 1)?.toIntOrNull() ?: 0; i++ }
            }
            i++
        }
    }
}

private val prefs: Preferences = Preferences.userRoot().node("app/cmv/desktop")
private val engineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

/** Windows 真实引擎在 W5 / W6 加入（engine-windows），之前一直返回 null */
private fun createRealEngine(): ControllerEngine? = null

private fun createEngine(choice: String): ControllerEngine {
    if (choice == REAL) {
        createRealEngine()?.let { return it }
        return FakeControllerEngine(FakeControllerEngine.Scenario.NONE, engineScope)
    }
    val scenario = FakeControllerEngine.Scenario.entries.firstOrNull { it.name == choice } ?: FakeControllerEngine.Scenario.MULTI
    return FakeControllerEngine(scenario, engineScope)
}

private val zh = Locale.getDefault().language == "zh"
private fun T(zhText: String, en: String) = if (zh) zhText else en

fun main(args: Array<String>) {
    val options = Options(args)
    application {
        var choice by remember { mutableStateOf(options.fakeScenario ?: prefs.get("engine", REAL)) }
        val engine = remember(choice) { createEngine(choice) }
        DisposableEffect(engine) { onDispose { engine.stop() } }
        val state by engine.state.collectAsState()
        var windowVisible by remember { mutableStateOf(true) }

        val trayState = rememberTrayState()
        var trayNoticeShown by remember { mutableStateOf(false) }
        LaunchedEffect(engine) {
            if (options.massage) {
                val controllers = engine.state.first { it.controllers.isNotEmpty() }.controllers
                controllers.forEach { engine.updateSettings(it.id, SettingsPatch(source = Source.MASSAGE)) }
            }
            if (options.autostart) engine.start()
        }

        fun quit() {
            engine.stop()
            exitApplication()
        }

        Tray(
            icon = TrayIcon,
            state = trayState,
            tooltip = "Controller Music Visualizer",
            onAction = { windowVisible = true },
            menu = {
                Item(T("显示窗口", "Show window"), onClick = { windowVisible = true })
                Item(if (state.running) T("停止", "Stop") else T("开始", "Start"),
                     enabled = state.running || state.canStart,
                     onClick = { if (state.running) engine.stop() else engine.start() })
                Separator()
                Item(T("退出", "Exit"), onClick = ::quit)
            },
        )

        // 关闭窗口 = 缩到托盘，引擎继续跑；从托盘菜单退出。
        // Windows 11 默认把新程序的托盘图标收进隐藏区，第一次关窗口时发通知，免得用户以为程序退出了
        Window(
            onCloseRequest = {
                windowVisible = false
                if (!trayNoticeShown) {
                    trayNoticeShown = true
                    trayState.sendNotification(Notification(
                        "Controller Music Visualizer",
                        T("已缩到托盘，仍在运行。从任务栏右下角（^ 里）的图标打开或退出。",
                          "Minimized to the tray and still running. Open or exit from the tray icon (under ^)."),
                    ))
                }
            },
            visible = windowVisible,
            title = "Controller Music Visualizer",
            state = rememberWindowState(size = DpSize(480.dp, 760.dp)),
        ) {
            ControllerApp(engine, initialSelection = options.select) { close ->
                fun pick(value: String) {
                    close()
                    prefs.put("engine", value)
                    choice = value
                }
                DropdownMenuItem(text = { Text((if (choice == REAL) "✓ " else "") + L("真实引擎", "Real engine")) },
                                 onClick = { pick(REAL) })
                HorizontalDivider()
                FakeControllerEngine.Scenario.entries.forEach { s ->
                    DropdownMenuItem(
                        text = { Text((if (choice == s.name) "✓ " else "") + L("假引擎：", "Fake engine: ") + s.title.text()) },
                        onClick = { pick(s.name) })
                }
            }
        }
    }
}

/** 托盘图标：画一个圆点，不带图片资源 */
private object TrayIcon : Painter() {
    override val intrinsicSize = Size(32f, 32f)
    override fun DrawScope.onDraw() {
        drawCircle(Color(0xFF3D5AFE))
        drawCircle(Color.White, radius = size.minDimension / 5)
    }
}
