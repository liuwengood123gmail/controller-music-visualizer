package app.cmv

import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.lifecycle.lifecycleScope
import app.cmv.engine.ControllerEngine
import app.cmv.engine.android.AndroidControllerEngine
import app.cmv.engine.fake.FakeControllerEngine
import app.cmv.ui.ControllerApp
import app.cmv.ui.L
import app.cmv.ui.text

/**
 * 组装界面和引擎。默认用真实引擎；右上角「⋮」可以切到假引擎的各个剧本（不需要手柄，调试界面用）。
 */
class MainActivity : ComponentActivity() {
    private lateinit var engine: ControllerEngine

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val prefs = getSharedPreferences("debug", MODE_PRIVATE)
        val choice = prefs.getString("engine", REAL) ?: REAL
        engine = if (choice == REAL) {
            try {
                AndroidControllerEngine.get(this)
            } catch (t: Throwable) {
                // 原生库加载失败等：退回假引擎，界面照样能用
                Log.e("cv-app", "real engine unavailable", t)
                Toast.makeText(this, "Engine failed to load: ${t.message}", Toast.LENGTH_LONG).show()
                FakeControllerEngine(FakeControllerEngine.Scenario.NONE, lifecycleScope)
            }
        } else {
            FakeControllerEngine(FakeControllerEngine.Scenario.valueOf(choice), lifecycleScope)
        }

        setContent {
            ControllerApp(engine) { close ->
                fun pick(value: String) {
                    close()
                    if (engine is AndroidControllerEngine && value != REAL) engine.stop()
                    prefs.edit().putString("engine", value).apply()
                    recreate()
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

    /** 手柄扳机轴（A 档调强度用）：转给真实引擎 */
    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        (engine as? AndroidControllerEngine)?.onMotionEvent(ev)
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun onPause() {
        super.onPause()
        (engine as? AndroidControllerEngine)?.clearAxes()
    }

    companion object { private const val REAL = "real" }
}
