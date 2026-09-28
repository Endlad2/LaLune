package com.lalune.app

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private val CHANNEL = "lalune/api"
    private val TAG = "LaLune"

    private val appDir: File by lazy { File(filesDir, "la-lune") }
    private val configsFile: File by lazy { File(appDir, "configs.json") }
    private val logsFile: File by lazy { File(appDir, "logs.log") }
    private val settingsFile: File by lazy { File(appDir, "settings.json") }
    private val tokenFile: File by lazy { File(appDir, "token.json") }

    private var configs = JSONArray()
    private var isConnected = false
    private var vkLoginInProgress = false
    private lateinit var coreManager: CoreManager
    private var smartTunnelManager: SmartTunnelManager? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        appDir.mkdirs()
        coreManager = CoreManager(this)
        loadConfigs()

        val deviceId = DeviceId.getOrCreate(this)
        DeviceId.syncToSettingsFile(this, deviceId)

        smartTunnelManager = SmartTunnelManager(this)
        if (readSettingBool("enableSmartTunnel", false)) {
            smartTunnelManager?.start()
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handleCall(call, result) }
    }

    // ============================================================
    //  MethodChannel dispatch
    // ============================================================

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "GetConfigsJson" -> result.success(configs.toString())
                "SaveConfig" -> {
                    val link = call.argument<String>("link") ?: ""
                    val protocol = call.argument<String>("protocol") ?: "CSQTT"
                    result.success(saveConfig(link, protocol))
                }
                "DeleteConfig" -> {
                    val id = (call.argument<Number>("id") ?: 0).toLong()
                    result.success(deleteConfig(id))
                }
                "GetSettingsJson" -> result.success(getSettingsJson())
                "SaveSettings" -> {
                    val json = call.argument<String>("json") ?: "{}"
                    result.success(saveSettings(json))
                }
                "GetLogsJson" -> result.success(getLogsJson())
                "ClearLogs" -> { logsFile.writeText(""); result.success(true) }
                "GetStatusJson" -> result.success("{\"connected\":$isConnected}")

                "Connect" -> {
                    val id = (call.argument<Number>("id") ?: 0).toLong()
                    result.success(connect(id))
                }
                "Disconnect" -> {
                    stopVpnService()
                    isConnected = false
                    result.success(true)
                }

                "CheckCoreUpdate" -> result.success("{\"update\":false,\"version\":\"\"}")
                "UpdateCoreAndWait" -> { result.success(true) }
                "CheckLaLuneUpdate" -> result.success("{\"update\":false,\"version\":\"0.6.0\"}")
                "OpenLaLuneReleases" -> {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW,
                            android.net.Uri.parse("https://github.com/Endlad2/LaLune/releases/latest")))
                        result.success(true)
                    } catch (_: Exception) { result.success(false) }
                }

                "GetVKTokenState" -> result.success(computeVkTokenState())
                "ValidateVKToken" -> result.success(computeVkTokenState())
                "VkLogin" -> result.success(vkLogin())
                "DeleteVKToken" -> {
                    try {
                        if (tokenFile.exists()) tokenFile.delete()
                        if (settingsFile.exists()) {
                            val j = JSONObject(settingsFile.readText())
                            j.put("vkJsToken", "")
                            settingsFile.writeText(j.toString())
                        }
                    } catch (_: Exception) {}
                    result.success(true)
                }
                "RunVkAutoApiCalls" -> result.success("{\"error\":\"not supported\"}")
                "PollAutoApiResult" -> result.success("{\"pending\":false}")
                "FinishVkCalls" -> result.success(false)

                "GetDeviceId" -> result.success(DeviceId.getOrCreate(this))
                "RegenerateDeviceId" -> {
                    val id = DeviceId.regenerate(this)
                    result.success(id)
                }

                "SetSelectedConfigJson" -> {
                    selectedConfigJson = call.argument<String>("json") ?: "{}"
                    result.success(true)
                }
                "GetSelectedConfigJson" -> result.success(selectedConfigJson)

                "IsCoreDownloading" -> result.success(false)
                "DeployProtocol" -> result.success(false)
                "DeployLog" -> result.success("")
                "IsDeploying" -> result.success(false)

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "MethodChannel error on ${call.method}: ${e.message}")
            result.error("EXCEPTION", e.message, null)
        }
    }

    private var selectedConfigJson: String = "{}"

    // ============================================================
    //  Configs
    // ============================================================

    private fun loadConfigs() {
        if (configsFile.exists()) {
            try { configs = JSONArray(configsFile.readText()) } catch (_: Exception) { configs = JSONArray() }
        }
    }

    private fun saveConfig(link: String, protocol: String): Boolean {
        val config = parseCsqttLink(link)
        val obj = JSONObject().apply {
            put("id", System.currentTimeMillis())
            put("protocol", protocol)
            put("peer", config.peer)
            put("password", config.password)
            put("hashes", config.hashes)
            put("name", config.peer)
            put("rawLink", link)
        }
        configs.put(obj)
        configsFile.writeText(configs.toString())
        return true
    }

    private fun deleteConfig(id: Long): Boolean {
        val newConfigs = JSONArray()
        for (i in 0 until configs.length()) {
            val obj = configs.getJSONObject(i)
            if (obj.getLong("id") != id) newConfigs.put(obj)
        }
        configs = newConfigs
        configsFile.writeText(configs.toString())
        return true
    }

    // ============================================================
    //  Settings
    // ============================================================

    private fun getSettingsJson(): String {
        val json = if (settingsFile.exists()) {
            try { JSONObject(settingsFile.readText()) } catch (_: Exception) { JSONObject() }
        } else JSONObject()

        if (!json.has("workers")) json.put("workers", 9)
        if (!json.has("autoApiWorkers")) json.put("autoApiWorkers", 9)
        if (!json.has("obfs")) json.put("obfs", "audio")
        if (!json.has("fingerprint")) json.put("fingerprint", "chrome")
        if (!json.has("clientIds")) json.put("clientIds", "8202606,6287487")
        if (!json.has("vkAuthMode")) json.put("vkAuthMode", "vkcalls")
        if (!json.has("captchaMode")) json.put("captchaMode", "auto")
        if (!json.has("authMode")) json.put("authMode", "manual")
        if (!json.has("turnTransport")) json.put("turnTransport", "udp")
        if (!json.has("enableSmartTunnel")) json.put("enableSmartTunnel", false)

        json.put("deviceId", DeviceId.getOrCreate(this))
        return json.toString()
    }

    private fun saveSettings(settingsJson: String): Boolean {
        return try {
            val incoming = JSONObject(settingsJson)
            val currentDeviceId = DeviceId.getOrCreate(this)
            incoming.put("deviceId", currentDeviceId)

            val oldSt = readSettingBool("enableSmartTunnel", false)
            val newSt = incoming.optBoolean("enableSmartTunnel", false)

            settingsFile.writeText(incoming.toString())

            if (oldSt != newSt) {
                if (newSt) smartTunnelManager?.start() else smartTunnelManager?.stop()
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "saveSettings: ${e.message}")
            false
        }
    }

    private fun readSettingBool(key: String, default: Boolean): Boolean =
        try {
            if (!settingsFile.exists()) default
            else JSONObject(settingsFile.readText()).optBoolean(key, default)
        } catch (_: Exception) { default }

    // ============================================================
    //  Logs
    // ============================================================

    private fun getLogsJson(): String {
        val logs = if (logsFile.exists()) logsFile.readText() else ""
        val lines = logs.split("\n").filter { it.isNotEmpty() }
        return JSONArray(lines).toString()
    }

    // ============================================================
    //  VK
    // ============================================================

    private fun computeVkTokenState(): String {
        var has = false
        if (tokenFile.exists()) {
            try {
                val j = JSONObject(tokenFile.readText())
                if (j.optString("Token", "").isNotBlank()) has = true
            } catch (_: Exception) {}
        }
        return JSONObject().apply {
            put("hasToken", has)
            put("fetcherOk", true)
            put("fetching", vkLoginInProgress)
            put("message", if (has) "Токен ВК активен" else "")
            put("progress", if (has) 100 else 0)
        }.toString()
    }

    private fun saveTokenToFile(token: String) {
        try {
            val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
                .apply { timeZone = TimeZone.getTimeZone("UTC") }
                .format(Date())
            tokenFile.writeText(JSONObject().apply {
                put("Token", token)
                put("SavedAt", iso)
            }.toString())
        } catch (_: Exception) {}
    }

    private fun vkLogin(): Boolean {
        if (vkLoginInProgress) return false
        runOnUiThread {
            try {
                vkLoginInProgress = true
                LaLuneTokenFetcherAndroid.fetchToken(
                    this,
                    object : LaLuneTokenFetcherAndroid.Callback {
                        override fun onSuccess(token: String) {
                            vkLoginInProgress = false
                            saveTokenToFile(token)
                        }
                        override fun onError(message: String) {
                            vkLoginInProgress = false
                            Log.w(TAG, "[VK] error: $message")
                        }
                    }
                )
            } catch (e: Exception) {
                vkLoginInProgress = false
                Log.e(TAG, "[VK] ${e.message}")
            }
        }
        return true
    }

    // ============================================================
    //  VPN
    // ============================================================

    private fun connect(configId: Long): Boolean {
        var peer = ""; var pwd = ""; var hashes = ""
        for (i in 0 until configs.length()) {
            val obj = configs.getJSONObject(i)
            if (obj.getLong("id") == configId) {
                peer = obj.optString("peer", "")
                pwd = obj.optString("password", "")
                hashes = obj.optString("hashes", "")
                break
            }
        }
        if (peer.isEmpty()) return false

        try {
            val j = if (settingsFile.exists()) JSONObject(settingsFile.readText()) else JSONObject()
            j.put("peer", peer)
            j.put("password", pwd)
            j.put("vkHashes", hashes)
            j.put("deviceId", DeviceId.getOrCreate(this))
            settingsFile.writeText(j.toString())
        } catch (_: Exception) { return false }

        runOnUiThread {
            val intent = android.net.VpnService.prepare(this)
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
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
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
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        smartTunnelManager?.stop()
    }

    // ============================================================
    //  Parsing
    // ============================================================

    data class ParsedConfig(val peer: String, val password: String, val hashes: String)

    private fun parseCsqttLink(link: String): ParsedConfig {
        var peer = link; var password = ""; var hashes = ""
        if (link.startsWith("csqtt://")) {
            try {
                val url = java.net.URI(link)
                if (url.host == "connect") {
                    val params = (url.query ?: "").split("&").associate {
                        val p = it.split("=")
                        if (p.size >= 2) p[0] to p[1] else p[0] to ""
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

    companion object {
        private const val REQ_VPN = 101
    }
}
