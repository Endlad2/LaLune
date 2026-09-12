package com.lalune.app

import android.annotation.SuppressLint
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class MainActivity : AppCompatActivity() {
    private lateinit var webView: WebView
    private val appDir: File by lazy { File(filesDir, "la-lune") }
    private val configsFile: File by lazy { File(appDir, "configs.json") }
    private val logsFile: File by lazy { File(appDir, "logs.txt") }
    private val settingsFile: File by lazy { File(appDir, "settings.json") }
    private val coreDir: File by lazy { File(appDir, "core") }

    private lateinit var coreManager: CoreManager
    private var configs = JSONArray()
    private var isConnected = false
    private var isCoreReady = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        appDir.mkdirs()
        coreDir.mkdirs()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            WebView.setWebContentsDebuggingEnabled(true)
        }

        val deviceId = DeviceId.getOrCreate(this)
        DeviceId.syncToSettingsFile(this, deviceId)
        android.util.Log.d("LaLune", "[DEVICE] deviceId = $deviceId")

        coreManager = CoreManager(this)
        loadConfigs()

        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.allowFileAccess = true
        webView.webViewClient = WebViewClient()
        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(msg: ConsoleMessage): Boolean {
                android.util.Log.d(
                    "LaLune-JS",
                    "${msg.message()} @ ${msg.sourceId()}:${msg.lineNumber()}"
                )
                return true
            }
        }
        webView.addJavascriptInterface(AndroidBridge(), "lalune")

        setContentView(webView)
        webView.loadUrl("file:///android_asset/app.html")

        scope.launch {
            isCoreReady = coreManager.checkCore()
            if (isCoreReady) {
                writeLog("[CORE] Ядро готово")
            } else {
                writeLog("[CORE] Ядро не найдено, будет скачано при подключении")
            }
        }
    }

    private fun loadConfigs() {
        if (configsFile.exists()) {
            try {
                configs = JSONArray(configsFile.readText())
            } catch (e: Exception) {
                configs = JSONArray()
            }
        }
    }

    private fun saveConfigs() {
        configsFile.writeText(configs.toString())
    }

    private fun writeLog(message: String) {
        logsFile.appendText(message + "\n")
        android.util.Log.d("LaLune", message)
    }

    inner class AndroidBridge {
        @JavascriptInterface
        fun getConfigs(): String = configs.toString()

        @JavascriptInterface
        fun getSettings(): String {
            val json = if (settingsFile.exists()) {
                try {
                    JSONObject(settingsFile.readText())
                } catch (e: Exception) {
                    JSONObject()
                }
            } else {
                JSONObject()
            }

            if (!json.has("workersPerHash")) json.put("workersPerHash", 9)
            if (!json.has("obfs")) json.put("obfs", "video")
            if (!json.has("fingerprint")) json.put("fingerprint", "firefox")
            if (!json.has("clientIds")) json.put("clientIds", "8202606,6287487")
            if (!json.has("vkAuthMode")) json.put("vkAuthMode", "vkcalls")
            if (!json.has("captchaMode")) json.put("captchaMode", "auto")
            if (!json.has("autoConnect")) json.put("autoConnect", false)

            json.put("deviceId", DeviceId.getOrCreate(this@MainActivity))
            return json.toString()
        }

        @JavascriptInterface
        fun getDeviceId(): String = DeviceId.getOrCreate(this@MainActivity)

        @JavascriptInterface
        fun regenerateDeviceId(): String {
            val fresh = DeviceId.regenerate(this@MainActivity)
            writeLog("[DEVICE] deviceId перегенерирован: $fresh")
            return fresh
        }

        @JavascriptInterface
        fun getLogs(): String {
            val logs = if (logsFile.exists()) logsFile.readText() else ""
            val lines = logs.split("\n").filter { it.isNotEmpty() }
            return JSONArray(lines).toString()
        }

        @JavascriptInterface
        fun getStatus(): String = "{\"connected\":$isConnected}"

        @JavascriptInterface
        fun saveConfig(link: String): Boolean {
            val config = parseCsqttLink(link)
            val obj = JSONObject().apply {
                put("id", System.currentTimeMillis())
                put("protocol", "CSQTT")
                put("peer", config.peer)
                put("password", config.password)
                put("hashes", config.hashes)
                put("name", config.peer)
            }
            configs.put(obj)
            saveConfigs()
            return true
        }

        @JavascriptInterface
        fun deleteConfig(id: Long): Boolean {
            val newConfigs = JSONArray()
            for (i in 0 until configs.length()) {
                val obj = configs.getJSONObject(i)
                if (obj.getLong("id") != id) newConfigs.put(obj)
            }
            configs = newConfigs
            saveConfigs()
            return true
        }

        @JavascriptInterface
        fun saveSettings(settingsJson: String): Boolean {
            return try {
                val incoming = JSONObject(settingsJson)
                val currentDeviceId = DeviceId.getOrCreate(this@MainActivity)
                incoming.put("deviceId", currentDeviceId)
                settingsFile.writeText(incoming.toString())
                true
            } catch (e: Exception) {
                writeLog("[SETTINGS] Ошибка сохранения: ${e.message}")
                false
            }
        }

        /**
         * Порядок:
         *   1. Достаём выбранный конфиг и синхронизируем в settings.json
         *      (чтобы LaLuneVpnService увидел те же peer/password/hashes).
         *   2. Проверяем VpnService.prepare() — если нужно разрешение, запрашиваем.
         *   3. Запускаем LaLuneVpnService, который сам стартует ядро и поднимет TUN
         *      когда в логе появится "[СТАТИСТИКА] Активных: N" с N > 0.
         *
         * Ядро из Activity больше НЕ запускается — только через сервис.
         */
        @JavascriptInterface
        fun connect(configId: Long): Boolean {
            var selectedPeer = ""
            var selectedPassword = ""
            var selectedHashes = ""

            synchronized(configs) {
                for (i in 0 until configs.length()) {
                    val obj = configs.getJSONObject(i)
                    if (obj.getLong("id") == configId) {
                        selectedPeer = obj.getString("peer")
                        selectedPassword = obj.getString("password")
                        selectedHashes = obj.getString("hashes")
                        break
                    }
                }
            }

            if (selectedPeer.isEmpty()) {
                writeLog("[VPN] Конфиг не найден")
                return false
            }

            try {
                val json = if (settingsFile.exists()) {
                    JSONObject(settingsFile.readText())
                } else {
                    JSONObject()
                }
                json.put("peer", selectedPeer)
                json.put("password", selectedPassword)
                json.put("vkHashes", selectedHashes)
                json.put("deviceId", DeviceId.getOrCreate(this@MainActivity))
                settingsFile.writeText(json.toString())
            } catch (e: Exception) {
                writeLog("[VPN] Не удалось сохранить выбранный конфиг: ${e.message}")
                return false
            }

            runOnUiThread {
                val intent = VpnService.prepare(this@MainActivity)
                if (intent != null) {
                    isConnected = true
                    startActivityForResult(intent, 100)
                } else {
                    startVpnService()
                    isConnected = true
                }
            }

            return true
        }

        @JavascriptInterface
        fun disconnect(): Boolean {
            stopVpnService()
            isConnected = false
            return true
        }

        @JavascriptInterface
        fun clearLogs(): Boolean {
            logsFile.writeText("")
            return true
        }

        @JavascriptInterface
        fun checkUpdate(): String = "{\"update\":false,\"version\":\"\"}"

        @JavascriptInterface
        fun updateCore(): Boolean {
            scope.launch { coreManager.checkCore() }
            return true
        }

        @JavascriptInterface
        fun updateCoreAndWait(): Boolean = true
    }

    private fun startVpnService() {
        val intent = Intent(this, LaLuneVpnService::class.java)
        intent.action = "START"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopVpnService() {
        val intent = Intent(this, LaLuneVpnService::class.java)
        intent.action = "STOP"
        try {
            startService(intent)
        } catch (e: Exception) {
            android.util.Log.w("LaLune", "stopVpnService: ${e.message}")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 100) {
            if (resultCode == RESULT_OK) {
                startVpnService()
                isConnected = true
            } else {
                isConnected = false
                writeLog("[VPN] Пользователь отклонил запрос разрешения")
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
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
            } catch (e: Exception) {}
        }

        return ParsedConfig(peer, password, hashes)
    }
}
