// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// MainActivity — FlutterActivity + MethodChannel «com.lalune.app/bridge».

package com.lalune.app

import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "LaLune"
        private const val CHANNEL = "com.lalune.app/bridge"
        private const val REQ_VPN = 101
        private const val DEFAULT_WORKERS = 9
        private const val MIN_WORKERS = 1
        private const val MAX_WORKERS = 127
        private const val DEFAULT_AUTO_API_WORKERS = 9
        private const val MIN_AUTO_API_WORKERS = 9
        private const val MAX_AUTO_API_WORKERS = 27
    }

    private val appDir: File by lazy { File(filesDir, "la-lune") }
    private val configsFile: File by lazy { File(appDir, "configs.json") }
    private val logsFile: File by lazy { File(appDir, "logs.log") }
    private val settingsFile: File by lazy { File(appDir, "settings.json") }
    private val tokenFile: File by lazy { File(appDir, "token.json") }
    private val coreDir: File by lazy { File(appDir, "core") }

    private lateinit var coreManager: CoreManager
    private var smartTunnelManager: SmartTunnelManager? = null

    private var configs = JSONArray()
    private var isConnected = false
    private var selectedConfigJson: String = "{}"
    private var vkLoginInProgress = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        appDir.mkdirs()
        coreDir.mkdirs()

        val deviceId = DeviceId.getOrCreate(this)
        DeviceId.syncToSettingsFile(this, deviceId)

        coreManager = CoreManager(this)
        loadConfigs()

        smartTunnelManager = SmartTunnelManager(this)
        if (readSettingBool("enableSmartTunnel", false)) {
            smartTunnelManager?.start()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getConfigs" -> result.success(configs.toString())
                    "saveConfig" -> result.success(saveConfig(call.argument<String>("link") ?: ""))
                    "deleteConfig" -> result.success(deleteConfig(call.argument<Number>("id")?.toLong() ?: 0L))
                    "getSettings" -> result.success(getSettings())
                    "saveSettings" -> result.success(saveSettings(call.argument<String>("settings") ?: ""))
                    "getLogs" -> result.success(getLogs())
                    "clearLogs" -> result.success(clearLogs())
                    "getStatus" -> result.success("{\"connected\":$isConnected}")
                    "connect" -> result.success(connect(call.argument<Number>("configId")?.toLong() ?: 0L))
                    "disconnect" -> { stopVpnService(); isConnected = false; result.success(true) }
                    "updateCore" -> { coreManager.checkCore(); result.success(true) }
                    "updateCoreAndWait" -> result.success(true)
                    "checkCoreUpdate" -> result.success("{\"update\":false,\"version\":\"\"}")
                    "checkLaLuneUpdate" -> result.success("{\"update\":false,\"version\":\"0.5.0\"}")
                    "openLaLuneReleases" -> { openLaLuneReleases(); result.success(true) }
                    "getVKTokenState" -> result.success(computeVkTokenState())
                    "validateVKToken" -> result.success(computeVkTokenState())
                    "vkLogin" -> result.success(vkLogin())
                    "deleteVKToken" -> result.success(deleteVKToken())
                    "runVkAutoApiCalls" -> result.success("{\"error\":\"not supported\"}")
                    "pollAutoApiResult" -> result.success("{\"pending\":false}")
                    "finishVkCalls" -> result.success(false)
                    "getDeviceId" -> result.success(DeviceId.getOrCreate(this))
                    "regenerateDeviceId" -> result.success(DeviceId.regenerate(this))
                    "getSelectedConfigJson" -> result.success(selectedConfigJson)
                    "setSelectedConfigJson" -> {
                        selectedConfigJson = call.argument<String>("json") ?: "{}"
                        result.success(true)
                    }
                    "isCoreDownloading" -> result.success(false)
                    else -> result.notImplemented()
                }
            }
    }

    private fun loadConfigs() {
        if (configsFile.exists()) {
            try { configs = JSONArray(configsFile.readText()) }
            catch (_: Exception) { configs = JSONArray() }
        }
    }

    private fun saveConfigs() { configsFile.writeText(configs.toString()) }

    private fun saveConfig(link: String): Boolean {
        val config = parseCsqttLink(link)
        val obj = JSONObject().apply {
            put("id", System.currentTimeMillis())
            put("protocol", "CSQTT")
            put("peer", config.peer)
            put("password", config.password)
            put("hashes", config.hashes)
            put("name", config.peer)
            put("rawLink", link)
        }
        configs.put(obj)
        saveConfigs()
        return true
    }

    private fun deleteConfig(id: Long): Boolean {
        val newConfigs = JSONArray()
        for (i in 0 until configs.length()) {
            val obj = configs.getJSONObject(i)
            if (obj.getLong("id") != id) newConfigs.put(obj)
        }
        configs = newConfigs
        saveConfigs()
        return true
    }

    private fun getSettings(): String {
        val json = if (settingsFile.exists()) {
            try { JSONObject(settingsFile.readText()) }
            catch (_: Exception) { JSONObject() }
        } else JSONObject()

        if (!json.has("workers")) json.put("workers", DEFAULT_WORKERS)
        if (!json.has("autoApiWorkers")) json.put("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
        if (!json.has("obfs")) json.put("obfs", "video")
        if (!json.has("fingerprint")) json.put("fingerprint", "firefox")
        if (!json.has("clientIds")) json.put("clientIds", "8202606,6287487")
        if (!json.has("vkAuthMode")) json.put("vkAuthMode", "vkcalls")
        if (!json.has("captchaMode")) json.put("captchaMode", "auto")
        if (!json.has("autoConnect")) json.put("autoConnect", false)
        if (!json.has("enableSmartTunnel")) json.put("enableSmartTunnel", false)

        json.put("deviceId", DeviceId.getOrCreate(this))
        return json.toString()
    }

    private fun saveSettings(settingsJson: String): Boolean {
        return try {
            val incoming = JSONObject(settingsJson)

            var w = incoming.optInt("workers", DEFAULT_WORKERS)
            if (w < MIN_WORKERS) w = MIN_WORKERS
            if (w > MAX_WORKERS) w = MAX_WORKERS
            incoming.put("workers", w)

            var aw = incoming.optInt("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
            if (aw < MIN_AUTO_API_WORKERS) aw = MIN_AUTO_API_WORKERS
            if (aw > MAX_AUTO_API_WORKERS) aw = MAX_AUTO_API_WORKERS
            incoming.put("autoApiWorkers", aw)

            val currentDeviceId = DeviceId.getOrCreate(this)
            incoming.put("deviceId", currentDeviceId)

            val oldSmartTunnel = readSettingBool("enableSmartTunnel", false)
            val newSmartTunnel = incoming.optBoolean("enableSmartTunnel", false)

            settingsFile.writeText(incoming.toString())

            if (oldSmartTunnel != newSmartTunnel) {
                if (newSmartTunnel) smartTunnelManager?.start() else smartTunnelManager?.stop()
            }
            true
        } catch (_: Exception) { false }
    }

    private fun readSettingBool(key: String, default: Boolean): Boolean {
        return try {
            if (!settingsFile.exists()) return default
            JSONObject(settingsFile.readText()).optBoolean(key, default)
        } catch (_: Exception) { default }
    }

    private fun getLogs(): String {
        val logs = if (logsFile.exists()) logsFile.readText() else ""
        val lines = logs.split("\n").filter { it.isNotEmpty() }
        return JSONArray(lines).toString()
    }

    private fun clearLogs(): Boolean {
        logsFile.writeText("")
        return true
    }

    private fun connect(configId: Long): Boolean {
        var peer = ""
        var password = ""
        var hashes = ""
        synchronized(configs) {
            for (i in 0 until configs.length()) {
                val obj = configs.getJSONObject(i)
                if (obj.getLong("id") == configId) {
                    peer = obj.getString("peer")
                    password = obj.getString("password")
                    hashes = obj.getString("hashes")
                    break
                }
            }
        }
        if (peer.isEmpty()) return false

        try {
            val json = if (settingsFile.exists()) JSONObject(settingsFile.readText()) else JSONObject()
            json.put("peer", peer)
            json.put("password", password)
            json.put("vkHashes", hashes)
            json.put("deviceId", DeviceId.getOrCreate(this))
            settingsFile.writeText(json.toString())
        } catch (_: Exception) { return false }

        runOnUiThread {
            val intent = VpnService.prepare(this)
            if (intent != null) {
                isConnected = true
                startActivityForResult(intent, REQ_VPN)
            } else {
                startVpnService()
                isConnected = true
            }
        }
        return true
    }

    private fun startVpnService() {
        val intent = Intent(this, LaLuneVpnService::class.java).apply { action = "START" }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
        else startService(intent)
    }

    private fun stopVpnService() {
        val intent = Intent(this, LaLuneVpnService::class.java).apply { action = "STOP" }
        try { startService(intent) } catch (_: Exception) {}
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            if (resultCode == RESULT_OK) {
                startVpnService()
                isConnected = true
            } else {
                isConnected = false
                writeLog("[VPN] Пользователь отклонил запрос разрешения")
            }
        }
    }

    private fun computeVkTokenState(): String {
        var hasToken = false
        if (tokenFile.exists()) {
            try {
                val j = JSONObject(tokenFile.readText())
                if (j.optString("Token", "").isNotBlank()) hasToken = true
            } catch (_: Exception) {}
        }
        if (!hasToken && settingsFile.exists()) {
            try {
                val j = JSONObject(settingsFile.readText())
                if (j.optString("vkJsToken", "").isNotBlank()) hasToken = true
            } catch (_: Exception) {}
        }

        val o = JSONObject()
        o.put("hasToken", hasToken)
        o.put("fetcherOk", true)
        o.put("fetching", vkLoginInProgress)
        o.put("message", if (hasToken) "Токен ВК активен" else "")
        o.put("progress", if (hasToken) 100 else 0)
        return o.toString()
    }

    private fun vkLogin(): Boolean {
        if (vkLoginInProgress) return false
        runOnUiThread {
            try {
                vkLoginInProgress = true
                writeLog("[VK] Открываю окно авторизации ВК...")
                LaLuneTokenFetcherAndroid.fetchToken(
                    this,
                    object : LaLuneTokenFetcherAndroid.Callback {
                        override fun onSuccess(token: String) {
                            vkLoginInProgress = false
                            saveTokenToFile(token)
                            writeLog("[VK] Токен получен успешно")
                        }
                        override fun onError(message: String) {
                            vkLoginInProgress = false
                            writeLog("[VK] Ошибка авторизации: $message")
                        }
                    }
                )
            } catch (e: Exception) {
                vkLoginInProgress = false
                writeLog("[VK] Не удалось открыть WebView: ${e.message}")
            }
        }
        return true
    }

    private fun deleteVKToken(): Boolean {
        try {
            if (tokenFile.exists()) tokenFile.delete()
            if (settingsFile.exists()) {
                val j = JSONObject(settingsFile.readText())
                j.put("vkJsToken", "")
                settingsFile.writeText(j.toString())
            }
        } catch (_: Exception) {}
        return true
    }

    private fun saveTokenToFile(token: String) {
        try {
            val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(Date())
            val j = JSONObject().apply {
                put("Token", token)
                put("SavedAt", iso)
            }
            tokenFile.writeText(j.toString())
        } catch (e: Exception) {
            writeLog("[VK] Ошибка сохранения токена: ${e.message}")
        }
    }

    private fun openLaLuneReleases() {
        try {
            startActivity(Intent(Intent.ACTION_VIEW,
                Uri.parse("https://github.com/Endlad2/LaLune/releases/latest")))
        } catch (_: Exception) {}
    }

    private fun writeLog(message: String) {
        logsFile.appendText(message + "\n")
        Log.d(TAG, message)
    }

    override fun onDestroy() {
        smartTunnelManager?.stop()
        super.onDestroy()
    }

    data class ParsedConfig(val peer: String, val password: String, val hashes: String)

    private fun parseCsqttLink(link: String): ParsedConfig {
        var peer = link
        var password = ""
        var hashes = ""
        if (link.startsWith("csqtt://")) {
            try {
                val url = java.net.URI(link)
                if (url.host == "connect") {
                    val query = url.query ?: ""
                    val params = query.split("&").associate {
                        val parts = it.split("=")
                        if (parts.size >= 2) parts[0] to parts[1] else parts[0] to ""
                    }
                    val host = params["host"] ?: ""
                    val port = params["peer"] ?: ""
                    password = params["password"] ?: ""
                    hashes = (params["hashes"] ?: "").replace("+", ",")
                    peer = "$host:$port"
                } else {
                    val host = url.host ?: ""
                    val port = if (url.port > 0) url.port else 46000
                    password = url.userInfo ?: ""
                    peer = "$host:$port"
                }
            } catch (_: Exception) {}
        }
        return ParsedConfig(peer, password, hashes)
    }
}
