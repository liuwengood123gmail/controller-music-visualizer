package app.cmv.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject

// 与 Swift 核心（Sources/ControllerCore/ControllerSettings.swift、SettingsPatch.swift）一一对应。
// JSON 字段名、枚举取值（Swift rawValue，中文）、默认值、夹值规则以 Swift 为准，由 contract/fixtures 双向校验。

/** 震动来源 */
enum class Source(val json: String) {
    MUSIC("跟随音乐"), MASSAGE("按摩");

    companion object { fun of(json: String?) = entries.firstOrNull { it.json == json } }
}

enum class MusicMode(val json: String) {
    BEAT("节拍"), BASS("低音"), ENVELOPE("包络");

    companion object { fun of(json: String?) = entries.firstOrNull { it.json == json } }
}

/** 内置按摩效果（顺序与 Swift 的 MassagePreset.allCases 相同，C 接口用下标表示「随机当前轮播到的」） */
enum class MassagePreset(val json: String) {
    KNEAD("揉捏"), TAP("敲击"), PAT("拍打"), SHIATSU("指压"), WAVE("波浪"), HEARTBEAT("心跳"),
    CRESCENDO("渐强"), ROLL("滚压"), STEADY("持续"), POUND("捶背"), GUN("按摩枪"), BREATHE("呼吸"),
    RAINDROP("雨滴"), RANDOM("随机");

    companion object { fun of(json: String?) = entries.firstOrNull { it.json == json } }
}

/** 一个手柄的全部设置（引擎持有，唯一真源） */
data class ControllerSettings(
    val enabled: Boolean = true,
    val source: Source = Source.MUSIC,
    val musicMode: MusicMode = MusicMode.BEAT,
    val sensitivity: Float = 0.5f,
    val responsiveness: Float = 0.7f,
    val preset: MassagePreset = MassagePreset.KNEAD,
    val speed: Double = 1.0,
    /** 0…3：超过 1 时把中低强度整体拉高 */
    val intensity: Float = 1f,
    val vibrationEnabled: Boolean = true,
    /** HD 震动（USB DualSense） */
    val hdEnabled: Boolean = true,
    val triggersEnabled: Boolean = true,
    val triggerResistance: Float = 0.5f,
    val lightEffects: Boolean = true,
    val lightSpeed: Float = 0.3f,
    val lightRange: Float = 1f,
    /** 手柄扬声器同步播放（USB DualSense），默认关 */
    val speakerEnabled: Boolean = false,
    val speakerVolume: Float = DEFAULT_SPEAKER_VOLUME,
) {
    /** 三项都交给游戏、扬声器也关：App 不碰手柄，等同于停止 */
    val allLeftToGame: Boolean get() = !vibrationEnabled && !triggersEnabled && !lightEffects && !speakerEnabled

    /** 把数值夹回合法范围（与 Swift 的 sanitized 相同） */
    fun sanitized(): ControllerSettings {
        fun unit(v: Float) = if (v.isFinite()) v.coerceIn(0f, 1f) else 0.5f
        return copy(
            sensitivity = unit(sensitivity), responsiveness = unit(responsiveness),
            triggerResistance = unit(triggerResistance), lightSpeed = unit(lightSpeed),
            lightRange = unit(lightRange), speakerVolume = unit(speakerVolume),
            intensity = if (intensity.isFinite()) intensity.coerceIn(0f, 3f) else 1f,
            speed = if (speed.isFinite()) speed.coerceIn(0.5, 2.0) else 1.0,
        )
    }

    fun toJsonObject(): JsonObject = JsonObject(
        linkedMapOf(
            "enabled" to JsonPrimitive(enabled), "source" to JsonPrimitive(source.json),
            "musicMode" to JsonPrimitive(musicMode.json), "sensitivity" to JsonPrimitive(sensitivity),
            "responsiveness" to JsonPrimitive(responsiveness), "preset" to JsonPrimitive(preset.json),
            "speed" to JsonPrimitive(speed), "intensity" to JsonPrimitive(intensity),
            "vibrationEnabled" to JsonPrimitive(vibrationEnabled), "hdEnabled" to JsonPrimitive(hdEnabled),
            "triggersEnabled" to JsonPrimitive(triggersEnabled), "triggerResistance" to JsonPrimitive(triggerResistance),
            "lightEffects" to JsonPrimitive(lightEffects), "lightSpeed" to JsonPrimitive(lightSpeed),
            "lightRange" to JsonPrimitive(lightRange), "speakerEnabled" to JsonPrimitive(speakerEnabled),
            "speakerVolume" to JsonPrimitive(speakerVolume),
        )
    )

    fun toJson(): String = toJsonObject().toString()

    companion object {
        const val DEFAULT_SPEAKER_VOLUME = 0.3f

        /** 缺字段或字段无效时用默认值（旧版本存档也能读），结果已夹值 */
        fun fromJson(o: JsonObject): ControllerSettings {
            val d = ControllerSettings()
            fun b(k: String, f: Boolean) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: f
            fun n(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
            fun fl(k: String, f: Float) = n(k)?.toFloat() ?: f
            fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return ControllerSettings(
                enabled = b("enabled", d.enabled),
                source = Source.of(s("source")) ?: d.source,
                musicMode = MusicMode.of(s("musicMode")) ?: d.musicMode,
                sensitivity = fl("sensitivity", d.sensitivity),
                responsiveness = fl("responsiveness", d.responsiveness),
                preset = MassagePreset.of(s("preset")) ?: d.preset,
                speed = n("speed") ?: d.speed,
                intensity = fl("intensity", d.intensity),
                vibrationEnabled = b("vibrationEnabled", d.vibrationEnabled),
                hdEnabled = b("hdEnabled", d.hdEnabled),
                triggersEnabled = b("triggersEnabled", d.triggersEnabled),
                triggerResistance = fl("triggerResistance", d.triggerResistance),
                lightEffects = b("lightEffects", d.lightEffects),
                lightSpeed = fl("lightSpeed", d.lightSpeed),
                lightRange = fl("lightRange", d.lightRange),
                speakerEnabled = b("speakerEnabled", d.speakerEnabled),
                speakerVolume = fl("speakerVolume", d.speakerVolume),
            ).sanitized()
        }

        fun fromJson(json: String): ControllerSettings =
            runCatching { fromJson(Json.parseToJsonElement(json).jsonObject) }.getOrDefault(ControllerSettings())

        /** 新手柄的初始设置（D5）：有记忆用记忆；否则复制当前选中手柄的设置（并启用）；都没有用默认值 */
        fun initial(remembered: ControllerSettings?, copying: ControllerSettings?): ControllerSettings =
            remembered ?: copying?.copy(enabled = true) ?: ControllerSettings()
    }
}

/** 设置补丁：只含要改的字段（界面 → 引擎）。引擎按「每个字段最后一次写入为准」合并 */
data class SettingsPatch(
    val enabled: Boolean? = null,
    val source: Source? = null,
    val musicMode: MusicMode? = null,
    val sensitivity: Float? = null,
    val responsiveness: Float? = null,
    val preset: MassagePreset? = null,
    val speed: Double? = null,
    val intensity: Float? = null,
    val vibrationEnabled: Boolean? = null,
    val hdEnabled: Boolean? = null,
    val triggersEnabled: Boolean? = null,
    val triggerResistance: Float? = null,
    val lightEffects: Boolean? = null,
    val lightSpeed: Float? = null,
    val lightRange: Float? = null,
    val speakerEnabled: Boolean? = null,
    val speakerVolume: Float? = null,
) {
    val isEmpty: Boolean get() = this == SettingsPatch()

    fun apply(s: ControllerSettings): ControllerSettings = s.copy(
        enabled = enabled ?: s.enabled, source = source ?: s.source, musicMode = musicMode ?: s.musicMode,
        sensitivity = sensitivity ?: s.sensitivity, responsiveness = responsiveness ?: s.responsiveness,
        preset = preset ?: s.preset, speed = speed ?: s.speed, intensity = intensity ?: s.intensity,
        vibrationEnabled = vibrationEnabled ?: s.vibrationEnabled, hdEnabled = hdEnabled ?: s.hdEnabled,
        triggersEnabled = triggersEnabled ?: s.triggersEnabled,
        triggerResistance = triggerResistance ?: s.triggerResistance,
        lightEffects = lightEffects ?: s.lightEffects, lightSpeed = lightSpeed ?: s.lightSpeed,
        lightRange = lightRange ?: s.lightRange, speakerEnabled = speakerEnabled ?: s.speakerEnabled,
        speakerVolume = speakerVolume ?: s.speakerVolume,
    ).sanitized()

    companion object {
        /** 两份设置之间的差异 */
        fun diff(old: ControllerSettings, new: ControllerSettings) = SettingsPatch(
            enabled = new.enabled.takeIf { it != old.enabled },
            source = new.source.takeIf { it != old.source },
            musicMode = new.musicMode.takeIf { it != old.musicMode },
            sensitivity = new.sensitivity.takeIf { it != old.sensitivity },
            responsiveness = new.responsiveness.takeIf { it != old.responsiveness },
            preset = new.preset.takeIf { it != old.preset },
            speed = new.speed.takeIf { it != old.speed },
            intensity = new.intensity.takeIf { it != old.intensity },
            vibrationEnabled = new.vibrationEnabled.takeIf { it != old.vibrationEnabled },
            hdEnabled = new.hdEnabled.takeIf { it != old.hdEnabled },
            triggersEnabled = new.triggersEnabled.takeIf { it != old.triggersEnabled },
            triggerResistance = new.triggerResistance.takeIf { it != old.triggerResistance },
            lightEffects = new.lightEffects.takeIf { it != old.lightEffects },
            lightSpeed = new.lightSpeed.takeIf { it != old.lightSpeed },
            lightRange = new.lightRange.takeIf { it != old.lightRange },
            speakerEnabled = new.speakerEnabled.takeIf { it != old.speakerEnabled },
            speakerVolume = new.speakerVolume.takeIf { it != old.speakerVolume },
        )

        /** 解析补丁 JSON（与 Swift 的 SettingsPatch Codable 相同：只含给出的字段） */
        fun fromJson(o: JsonObject): SettingsPatch {
            fun n(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
            fun b(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
            fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return SettingsPatch(
                enabled = b("enabled"), source = Source.of(s("source")), musicMode = MusicMode.of(s("musicMode")),
                sensitivity = n("sensitivity")?.toFloat(), responsiveness = n("responsiveness")?.toFloat(),
                preset = MassagePreset.of(s("preset")), speed = n("speed"), intensity = n("intensity")?.toFloat(),
                vibrationEnabled = b("vibrationEnabled"), hdEnabled = b("hdEnabled"),
                triggersEnabled = b("triggersEnabled"), triggerResistance = n("triggerResistance")?.toFloat(),
                lightEffects = b("lightEffects"), lightSpeed = n("lightSpeed")?.toFloat(),
                lightRange = n("lightRange")?.toFloat(), speakerEnabled = b("speakerEnabled"),
                speakerVolume = n("speakerVolume")?.toFloat(),
            )
        }
    }
}

internal fun JsonElement.asObject(): JsonObject = jsonObject
