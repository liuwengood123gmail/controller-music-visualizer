package app.cmv.engine.android

import android.content.Context
import app.cmv.engine.ControllerSettings
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** 按手柄身份记住设置（所有手柄合成一个 JSON，键 controllerSettings.v1，格式同 macOS 的 SettingsStore） */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("engine", Context.MODE_PRIVATE)

    private fun loadAll(): MutableMap<String, JsonObject> = runCatching {
        Json.parseToJsonElement(prefs.getString(KEY, null) ?: "{}").jsonObject.mapValues { it.value.jsonObject }.toMutableMap()
    }.getOrDefault(mutableMapOf())

    fun load(key: String): ControllerSettings? = loadAll()[key]?.let { ControllerSettings.fromJson(it) }

    fun save(all: Map<String, ControllerSettings>) {
        val m = loadAll()
        for ((k, v) in all) m[k] = v.toJsonObject()
        prefs.edit().putString(KEY, JsonObject(m).toString()).apply()
    }

    companion object { const val KEY = "controllerSettings.v1" }
}
