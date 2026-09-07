package com.lalune.app

import android.annotation.SuppressLint
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class MainActivity : AppCompatActivity() {
    private lateinit var webView: WebView
    private val appDir: File by lazy { File(filesDir, "la-lune") }
    private val configsFile: File by lazy { File(appDir, "configs.json") }
    private val logsFile: File by lazy { File(appDir, "logs.txt") }
    private val coreDir: File by lazy { File(appDir, "core") }
    private val latestFile: File by lazy { File(appDir, "LATEST") }
    private var configs = JSONArray()
    private var isConnected = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Создаём папку la-lune
        appDir.mkdirs()
        coreDir.mkdirs()

        // Загружаем конфиги
        loadConfigs()

        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.allowFileAccess = true
        webView.webViewClient = WebViewClient()
        webView.webChromeClient = WebChromeClient()

        // Добавляем JS мост
        webView.addJavascriptInterface(AndroidBridge(), "lalune")

        setContentView(webView)

        // Загружаем HTML
        webView.loadUrl("file:///android_asset/app.html")
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
    }

    inner class AndroidBridge {
        @JavascriptInterface
        fun getConfigs(): String {
            return configs.toString()
        }

        @JavascriptInterface
        fun getSettings(): String {
            val settingsFile = File(appDir, "settings.json")
            if (settingsFile.exists()) {
                return settingsFile.readText()
            }
            val default = JSONObject().apply {
                put("workersPerHash", 9)
                put("obfs", "video")
                put("fingerprint", "firefox")
                put("clientIds", "8202606,6287487")
                put("vkAuthMode", "vkcalls")
                put("captchaMode", "auto")
                put("deviceId", java.util.UUID.randomUUID().toString().replace("-", ""))
            }
            return default.toString()
        }

        @JavascriptInterface
        fun getLogs(): String {
            if (!logsFile.exists()) return "[]"
            val lines = logsFile.readLines().filter { it.isNotEmpty() }
            return JSONArray(lines).toString()
        }

        @JavascriptInterface
        fun getStatus(): String {
            return "{\"connected\":$isConnected}"
        }

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
                if (obj.getLong("id") != id) {
                    newConfigs.put(obj)
                }
            }
            configs = newConfigs
            saveConfigs()
            return true
        }

        @JavascriptInterface
        fun saveSettings(settingsJson: String): Boolean {
            val settingsFile = File(appDir, "settings.json")
            settingsFile.writeText(settingsJson)
            return true
        }

        @JavascriptInterface
        fun connect(configId: Long): Boolean {
            // Находим конфиг
            var selectedPeer = ""
            var selectedPassword = ""
            var selectedHashes = ""
            for (i in 0 until configs.length()) {
                val obj = configs.getJSONObject(i)
                if (obj.getLong("id") == configId) {
                    selectedPeer = obj.getString("peer")
                    selectedPassword = obj.getString("password")
                    selectedHashes = obj.getString("hashes")
                    break
                }
            }

            if (selectedPeer.isEmpty()) return false

            // Проверяем ядро
            val corePath = ensureCore()
            if (corePath == null) return false

            // Сохраняем параметры для VPN сервиса
            getSharedPreferences("lalune", MODE_PRIVATE).edit().apply {
                putString("peer", selectedPeer)
                putString("password", selectedPassword)
                putString("hashes", selectedHashes)
                putString("corePath", corePath)
                putString("coreDir", coreDir.absolutePath)
                apply()
            }

            // Запускаем VPN
            val intent = VpnService.prepare(this)
            if (intent != null) {
                startActivityForResult(intent, 100)
            } else {
                startVpn()
            }
            return true
        }

        @JavascriptInterface
        fun disconnect(): Boolean {
            val intent = Intent(this@MainActivity, LaLuneVpnService::class.java)
            intent.action = "DISCONNECT"
            startService(intent)
            isConnected = false
            return true
        }

        @JavascriptInterface
        fun clearLogs(): Boolean {
            logsFile.writeText("")
            return true
        }

        @JavascriptInterface
        fun checkUpdate(): String {
            return "{\"update\":false,\"version\":\"\"}"
        }

        @JavascriptInterface
        fun updateCore(): Boolean {
            return true
        }

        @JavascriptInterface
        fun updateCoreAndWait(): Boolean {
            return true
        }
    }

    private fun ensureCore(): String? {
        // Определяем архитектуру
        val arch = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
        val coreName = when {
            arch.contains("arm64") -> "client-linux-arm64"
            arch.contains("arm") -> "client-linux-armv7"
            arch.contains("x86_64") -> "client-linux-x86_64"
            else -> return null
        }

        val coreFile = File(coreDir, coreName)
        if (coreFile.exists()) {
            return coreFile.absolutePath
        }

        // Скачиваем ядро по latest
        val latest = fetchURL("https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST")
        if (latest == null) return null

        val tag = latest.trim()
        val url = "https://github.com/Endlad2/csqtt-core/releases/download/$tag/$coreName"

        writeLog("[CORE] Скачивание $coreName (тег: $tag)...")

        val success = downloadFile(url, coreFile)
        if (success) {
            coreFile.setExecutable(true)
            latestFile.writeText(tag)
            writeLog("[CORE] Ядро установлено")
            return coreFile.absolutePath
        }

        return null
    }

    private fun fetchURL(urlStr: String): String? {
        // Уровень 1: прямой
        try {
            val conn = java.net.URL(urlStr).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", "Mozilla/5.0")
            if (conn.responseCode == 200) {
                return conn.inputStream.bufferedReader().readText()
            }
        } catch (e: Exception) {}

        // Уровень 2: через прокси
        try {
            val proxyURL = "http://31.77.148.203:8855/?url=" + java.net.URLEncoder.encode(urlStr, "UTF-8")
            val conn = java.net.URL(proxyURL).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            if (conn.responseCode == 200) {
                return conn.inputStream.bufferedReader().readText()
            }
        } catch (e: Exception) {}

        // Уровень 3: через прокси с другим UA
        try {
            val proxyURL = "http://31.77.148.203:8855/?url=" + java.net.URLEncoder.encode(urlStr, "UTF-8")
            val conn = java.net.URL(proxyURL).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", "curl/7.68.0")
            if (conn.responseCode == 200) {
                return conn.inputStream.bufferedReader().readText()
            }
        } catch (e: Exception) {}

        return null
    }

    private fun downloadFile(urlStr: String, dest: File): Boolean {
        // Уровень 1: прямой
        try {
            val conn = java.net.URL(urlStr).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", "Mozilla/5.0")
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
                return dest.length() > 1024
            }
        } catch (e: Exception) {}

        // Уровень 2: через прокси
        try {
            val proxyURL = "http://31.77.148.203:8855/?url=" + java.net.URLEncoder.encode(urlStr, "UTF-8")
            val conn = java.net.URL(proxyURL).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
                return dest.length() > 1024
            }
        } catch (e: Exception) {}

        // Уровень 3
        try {
            val proxyURL = "http://31.77.148.203:8855/?url=" + java.net.URLEncoder.encode(urlStr, "UTF-8")
            val conn = java.net.URL(proxyURL).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", "curl/7.68.0")
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
                return dest.length() > 1024
            }
        } catch (e: Exception) {}

        return false
    }

    private fun startVpn() {
        val intent = Intent(this, LaLuneVpnService::class.java)
        intent.action = "CONNECT"
        startService(intent)
        isConnected = true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 100 && resultCode == RESULT_OK) {
            startVpn()
        }
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
