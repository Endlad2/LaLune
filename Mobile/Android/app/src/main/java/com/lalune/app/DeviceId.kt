package com.lalune.app

import android.content.Context
import java.io.File
import java.util.UUID

/**
 * Утилита для работы с device-id.
 *
 * Формат: hex-строка без дефисов (32 символа), например:
 *   1a25562741d5a2643f8b9e12c4d5f6a7
 *
 * Хранится в files/la-lune/settings.json в ключе "deviceId".
 * Генерируется один раз при первом запуске и сохраняется.
 * Может быть перегенерирован через UI (кнопка "Перегенерировать").
 */
object DeviceId {

    private const val PREFS_NAME = "lalune_prefs"
    private const val KEY_DEVICE_ID = "deviceId"

    /**
     * Возвращает сохранённый deviceId, а если его нет — генерирует
     * новый, сохраняет в SharedPreferences (быстро, надёжно, доступно
     * даже до того как фронт загрузит settings.json) и возвращает.
     */
    fun getOrCreate(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existing = prefs.getString(KEY_DEVICE_ID, null)
        if (!existing.isNullOrBlank()) {
            return existing
        }
        val generated = generate()
        prefs.edit().putString(KEY_DEVICE_ID, generated).apply()
        return generated
    }

    /**
     * Принудительно генерирует новый deviceId и сохраняет его.
     * Используется кнопкой "Перегенерировать" в настройках.
     */
    fun regenerate(context: Context): String {
        val fresh = generate()
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_DEVICE_ID, fresh).apply()

        // Дублируем в settings.json, чтобы CoreManager.startCore() его видел,
        // даже если UI ещё не успел перезаписать файл.
        syncToSettingsFile(context, fresh)

        return fresh
    }

    /**
     * Записывает deviceId в settings.json (создаёт файл, если его нет).
     * Остальные поля не трогает — только ключ "deviceId".
     */
    fun syncToSettingsFile(context: Context, deviceId: String) {
        try {
            val appDir = File(context.filesDir, "la-lune")
            if (!appDir.exists()) appDir.mkdirs()

            val settingsFile = File(appDir, "settings.json")
            val json = if (settingsFile.exists()) {
                try {
                    org.json.JSONObject(settingsFile.readText())
                } catch (e: Exception) {
                    org.json.JSONObject()
                }
            } else {
                org.json.JSONObject()
            }

            json.put("deviceId", deviceId)
            settingsFile.writeText(json.toString())
        } catch (e: Exception) {
            android.util.Log.e("LaLune", "syncToSettingsFile failed: ${e.message}")
        }
    }

    private fun generate(): String {
        // 32 hex-символа без дефисов — тот же формат, что и на десктопе
        return UUID.randomUUID().toString().replace("-", "")
    }
}
