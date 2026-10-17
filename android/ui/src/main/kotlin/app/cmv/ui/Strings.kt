package app.cmv.ui

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import app.cmv.engine.Bilingual
import app.cmv.engine.Language
import app.cmv.engine.MassagePreset
import app.cmv.engine.MusicMode
import app.cmv.engine.Source
import java.util.Locale

val LocalLanguage = staticCompositionLocalOf { Language.ZH }

/** 按当前语言取文字 */
@Composable @ReadOnlyComposable
fun L(zh: String, en: String): String = if (LocalLanguage.current == Language.ZH) zh else en

@Composable @ReadOnlyComposable
fun Bilingual.text(): String = text(LocalLanguage.current)

/** 语言选择存在界面自己的 SharedPreferences 里；未选择时跟随系统语言 */
object LanguageStore {
    private const val PREFS = "ui"
    private const val KEY = "language"

    fun load(context: Context): Language {
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
        return Language.entries.firstOrNull { it.name == saved }
            ?: if (Locale.getDefault().language == "zh") Language.ZH else Language.EN
    }

    fun save(context: Context, language: Language) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, language.name).apply()
    }
}

val Source.title: Bilingual
    get() = when (this) {
        Source.MUSIC -> Bilingual("跟随音乐", "Music")
        Source.MASSAGE -> Bilingual("按摩", "Massage")
    }

val MusicMode.title: Bilingual
    get() = when (this) {
        MusicMode.BEAT -> Bilingual("节拍", "Beat")
        MusicMode.BASS -> Bilingual("低音", "Bass")
        MusicMode.ENVELOPE -> Bilingual("包络", "Envelope")
    }

val MassagePreset.title: Bilingual
    get() = when (this) {
        MassagePreset.KNEAD -> Bilingual("揉捏", "Knead")
        MassagePreset.TAP -> Bilingual("敲击", "Tap")
        MassagePreset.PAT -> Bilingual("拍打", "Pat")
        MassagePreset.SHIATSU -> Bilingual("指压", "Shiatsu")
        MassagePreset.WAVE -> Bilingual("波浪", "Wave")
        MassagePreset.HEARTBEAT -> Bilingual("心跳", "Heartbeat")
        MassagePreset.CRESCENDO -> Bilingual("渐强", "Crescendo")
        MassagePreset.ROLL -> Bilingual("滚压", "Roll")
        MassagePreset.STEADY -> Bilingual("持续", "Steady")
        MassagePreset.POUND -> Bilingual("捶背", "Pound")
        MassagePreset.GUN -> Bilingual("按摩枪", "Gun")
        MassagePreset.BREATHE -> Bilingual("呼吸", "Breathe")
        MassagePreset.RAINDROP -> Bilingual("雨滴", "Rain")
        MassagePreset.RANDOM -> Bilingual("随机", "Random")
    }

/** 预设图标：用字符，不引入整套图标库 */
val MassagePreset.glyph: String
    get() = when (this) {
        MassagePreset.KNEAD -> "👐"
        MassagePreset.TAP -> "👆"
        MassagePreset.PAT -> "👏"
        MassagePreset.SHIATSU -> "👍"
        MassagePreset.WAVE -> "🌊"
        MassagePreset.HEARTBEAT -> "❤"
        MassagePreset.CRESCENDO -> "📈"
        MassagePreset.ROLL -> "↔"
        MassagePreset.STEADY -> "➖"
        MassagePreset.POUND -> "🔨"
        MassagePreset.GUN -> "⚡"
        MassagePreset.BREATHE -> "🌬"
        MassagePreset.RAINDROP -> "🌧"
        MassagePreset.RANDOM -> "🔀"
    }
