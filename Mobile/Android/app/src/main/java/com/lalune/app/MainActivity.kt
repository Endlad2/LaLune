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
    
    private lateinit var termuxManager: TermuxManager
    private lateinit var tunManager: TunManager
    private var configs = JSONArray()
    private var isConnected = false
    private var isCoreReady = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        appDir.mkdirs()
        
        termuxManager = TermuxManager(this)
        tunManager = TunManager(object : VpnService() {
            override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
                return START_STICKY
            }
        })
        
        loadConfigs()
        
        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.allowFileAccess = true
        webView.webViewClient = WebViewClient()
        webView.webChromeClient = WebChromeClient()
        webView.addJavascriptInterface(AndroidBridge(), "lalune")
        
        setContentView(webView)
        webView.loadUrl("file:///android_asset/app.html")
        
        // Предзагрузка ядра
        scope.launch {
            isCoreReady = termuxManager.ensureCore()
            if (isCoreReady) {
                writeLog("[CORE] Ядро готово")
            } else {
                writeLog("[CORE] Ошибка подготовки ядра")
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
    }
    
    inner class AndroidBridge {
        @JavascriptInterface
        fun getConfigs(): String {
            return configs.toString()
        }
        
        @JavascriptInterface
        fun getSettings(): String {
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
            val logs = termuxManager.getLogs()
            val lines = logs.split("\n").filter { it.isNotEmpty() }
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
            settingsFile.writeText(settingsJson)
            return true
        }
        
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
            
            // Запускаем ядро через Termux
            val settings = if (settingsFile.exists()) {
                try {
                    JSONObject(settingsFile.readText())
                } catch (e: Exception) {
                    JSONObject()
                }
            } else {
                JSONObject()
            }
            
            val workers = settings.optInt("workersPerHash", 9)
            
            val success = termuxManager.runCoreViaTermux(
                peer = selectedPeer,
                password = selectedPassword,
                hashes = selectedHashes,
                workers = workers
            )
            
            if (!success) {
                writeLog("[VPN] Ошибка запуска ядра")
                return false
            }
            
            // Запускаем VPN
            val intent = VpnService.prepare(this@MainActivity)
            if (intent != null) {
                startActivityForResult(intent, 100)
            } else {
                startVpn()
            }
            
            isConnected = true
            return true
        }
        
        @JavascriptInterface
        fun disconnect(): Boolean {
            termuxManager.stopCore()
            tunManager.stop()
            isConnected = false
            return true
        }
        
        @JavascriptInterface
        fun clearLogs(): Boolean {
            termuxManager.clearLogs()
            return true
        }
        
        @JavascriptInterface
        fun checkUpdate(): String {
            return "{\"update\":false,\"version\":\"\"}"
        }
        
        @JavascriptInterface
        fun updateCore(): Boolean {
            scope.launch {
                isCoreReady = termuxManager.ensureCore()
            }
            return true
        }
        
        @JavascriptInterface
        fun updateCoreAndWait(): Boolean {
            return true
        }
    }
    
    private fun startVpn() {
        // Запускаем TUN менеджер
        tunManager.start { success ->
            if (success) {
                writeLog("[VPN] Туннель запущен")
            } else {
                writeLog("[VPN] Ошибка запуска туннеля")
            }
        }
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 100 && resultCode == RESULT_OK) {
            startVpn()
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        tunManager.stop()
        termuxManager.stopCore()
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
