// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.lalune.app

import android.content.Context
import java.io.File
import java.util.UUID

object DeviceId {

    private const val PREFS_NAME = "lalune_prefs"
    private const val KEY_DEVICE_ID = "deviceId"

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

    fun regenerate(context: Context): String {
        val fresh = generate()
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_DEVICE_ID, fresh).apply()
        syncToSettingsFile(context, fresh)
        return fresh
    }

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
        return UUID.randomUUID().toString().replace("-", "")
    }
}
