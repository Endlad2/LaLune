package com.lalune.app

import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class MainActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "LaLune"
        private const val REQ_NOTIFICATIONS = 100
        private const val REQ_VPN = 101
        private const val REQ_BATTERY = 200
        private const val PREFS = "lalune_prefs"
        private const val PREF_ONBOARDING_DONE = "onboarding_done"

        private const val ASSET_HOST = "appassets.androidplatform.net"
        private const val ASSET_URL = "https://$ASSET_HOST/assets/app.html"

        private const val DEFAULT_WORKERS = 9
        private const val MIN_WORKERS = 1
        private const val MAX_WORKERS = 127
        private const val DEFAULT_AUTO_API_WORKERS = 9
        private const val MIN_AUTO_API_WORKERS = 9
        private const val MAX_AUTO_API_WORKERS = 27
    }

    private lateinit var webView: WebView
    private lateinit var assetLoader: WebViewAssetLoader

    private val appDir: File by lazy { File(filesDir, "la-lune") }
    private val configsFile: File by lazy { File(appDir, "configs.json") }
    private val logsFile: File by lazy { File(appDir, "logs.log") }
    private val settingsFile: File by lazy { File(appDir, "settings.json") }
    private val tokenFile: File by lazy { File(appDir, "token.json") }
    private val coreDir: File by lazy { File(appDir, "core") }

    private lateinit var coreManager: CoreManager
    private var configs = JSONArray()
    private var isConnected = false
    private var isCoreReady = false

    private var selectedConfigJson: String = "{}"
    private var vkLoginInProgress = false

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
        Log.d(TAG, "[DEVICE] deviceId = $deviceId")

        coreManager = CoreManager(this)
        loadConfigs()

        assetLoader = WebViewAssetLoader.Builder()
            .setDomain(ASSET_HOST)
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()

        setupWebView()

        setContentView(webView)
        webView.loadUrl(ASSET_URL)

        scope.launch {
            isCoreReady = coreManager.checkCore()
        }

        runOnUiThread { startOnboarding() }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.allowFileAccess = true
        webView.settings.allowContentAccess = true
        webView.settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_ALWAYS_ALLOW

        webView.webViewClient = object : WebViewClientCompat() {
            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest
            ): WebResourceResponse? {
                return assetLoader.shouldInterceptRequest(request.url)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(msg: ConsoleMessage): Boolean {
                Log.d("LaLune-JS", "${msg.message()} @ ${msg.sourceId()}:${msg.lineNumber()}")
                return true
            }
        }

        webView.addJavascriptInterface(AndroidBridge(), "lalune")
    }

    private fun startOnboarding() {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        val done = prefs.getBoolean(PREF_ONBOARDING_DONE, false)
        if (done) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED

            if (!granted) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    REQ_NOTIFICATIONS
                )
                return
            }
        }

        openBatteryOptimizationSettings()
    }

    private fun openBatteryOptimizationSettings() {
        val pkg = packageName

        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$pkg")
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivityForResult(intent, REQ_BATTERY)
                return
            }
        } catch (_: Exception) {}

        try {
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            if (intent.resolveActivity(packageManager) != null) {
                startActivityForResult(intent, REQ_BATTERY)
                return
            }
        } catch (_: Exception) {}

        try {
            val intent = Intent().apply {
                setClassName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                )
                putExtra("package_name", pkg)
                putExtra("package_label", "LaLune")
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivityForResult(intent, REQ_BATTERY)
                return
            }
        } catch (_: Exception) {}

        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$pkg")
            }
            startActivityForResult(intent, REQ_BATTERY)
        } catch (_: Exception) {
            markOnboardingDone()
        }
    }

    private fun markOnboardingDone() {
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_ONBOARDING_DONE, true)
            .apply()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFICATIONS) {
            openBatteryOptimizationSettings()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            REQ_VPN -> {
                if (resultCode == RESULT_OK) {
                    startVpnService()
                    isConnected = true
                } else {
                    isConnected = false
                    writeLog("[VPN] Пользователь отклонил запрос разрешения")
                }
            }
            REQ_BATTERY -> {
                markOnboardingDone()
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
        Log.d(TAG, message)
    }

    // ============================================================
    //  VK token
    // ============================================================

    private fun saveTokenToFile(token: String) {
        try {
            val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(Date())

            val j = JSONObject()
            j.put("Token", token)
            j.put("SavedAt", iso)

            tokenFile.writeText(j.toString())
            writeLog("[VK] Токен сохранён в token.json")
        } catch (e: Exception) {
            writeLog("[VK] Ошибка сохранения токена: ${e.message}")
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

    /// Вызывает JS-функцию window._vkLoginCallback(success, payload).
    /// На Android WebView метод называется evaluateJavascript (не evaluateJavaScript),
    /// и callback — ValueCallback<String>?, а не null.
    private fun notifyJsTokenReceived(success: Boolean, payload: String) {
        val jsPayload = payload
            .replace("\\", "\\\\")
            .replace("'", "\\'")
            .replace("\n", "\\n")
            .replace("\r", "\\r")

        val js = "if(window._vkLoginCallback){window._vkLoginCallback($success,'$jsPayload');}"

        runOnUiThread {
            try {
                webView.evaluateJavascript(js, ValueCallback<String> { /* ignore result */ })
            } catch (_: Exception) {}
        }
    }

    // ============================================================
    //  JS Bridge
    // ============================================================

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

            if (!json.has("workers")) json.put("workers", DEFAULT_WORKERS)
            if (!json.has("autoApiWorkers")) json.put("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
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
        fun regenerateDeviceId(): String = DeviceId.regenerate(this@MainActivity)

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
                put("rawLink", link)
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

                var w = incoming.optInt("workers", DEFAULT_WORKERS)
                if (w < MIN_WORKERS) w = MIN_WORKERS
                if (w > MAX_WORKERS) w = MAX_WORKERS
                incoming.put("workers", w)

                var aw = incoming.optInt("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
                if (aw < MIN_AUTO_API_WORKERS) aw = MIN_AUTO_API_WORKERS
                if (aw > MAX_AUTO_API_WORKERS) aw = MAX_AUTO_API_WORKERS
                incoming.put("autoApiWorkers", aw)

                val currentDeviceId = DeviceId.getOrCreate(this@MainActivity)
                incoming.put("deviceId", currentDeviceId)

                settingsFile.writeText(incoming.toString())
                true
            } catch (e: Exception) {
                false
            }
        }

        @JavascriptInterface
        fun setSelectedConfigJson(json: String): Boolean {
            selectedConfigJson = json
            return true
        }

        @JavascriptInterface
        fun getSelectedConfigJson(): String = selectedConfigJson

        @JavascriptInterface
        fun isCoreDownloading(): Boolean = false

        @JavascriptInterface
        fun getVKTokenState(): String = computeVkTokenState()

        @JavascriptInterface
        fun validateVKToken(): String = computeVkTokenState()

        /// VkLogin — открывает WebView с OAuth ВК через LaLuneTokenFetcherAndroid.
        @JavascriptInterface
        fun vkLogin(): Boolean {
            if (vkLoginInProgress) {
                Log.d(TAG, "[VK] Login уже в процессе")
                return false
            }

            runOnUiThread {
                try {
                    vkLoginInProgress = true
                    writeLog("[VK] Открываю окно авторизации ВК...")

                    LaLuneTokenFetcherAndroid.fetchToken(
                        this@MainActivity,
                        object : LaLuneTokenFetcherAndroid.Callback {
                            override fun onSuccess(token: String) {
                                vkLoginInProgress = false
                                saveTokenToFile(token)
                                writeLog("[VK] Токен получен успешно")
                                notifyJsTokenReceived(true, token)
                            }

                            override fun onError(message: String) {
                                vkLoginInProgress = false
                                writeLog("[VK] Ошибка авторизации: $message")
                                notifyJsTokenReceived(false, message)
                            }
                        }
                    )
                } catch (e: Exception) {
                    vkLoginInProgress = false
                    writeLog("[VK] Не удалось открыть WebView: ${e.message}")
                    notifyJsTokenReceived(false, e.message ?: "unknown error")
                }
            }
            return true
        }

        @JavascriptInterface
        fun deleteVKToken(): Boolean {
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

            if (selectedPeer.isEmpty()) return false

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
                return false
            }

            runOnUiThread {
                val intent = VpnService.prepare(this@MainActivity)
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

        @JavascriptInterface
        fun checkCoreUpdate(): String = "{\"update\":false,\"version\":\"\"}"

        @JavascriptInterface
        fun checkLaLuneUpdate(): String = "{\"update\":false,\"version\":\"0.5.0\"}"

        @JavascriptInterface
        fun openLaLuneReleases(): Boolean {
            return try {
                val intent = Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://github.com/Endlad2/LaLune/releases/latest")
                )
                startActivity(intent)
                true
            } catch (e: Exception) {
                false
            }
        }

        @JavascriptInterface
        fun runVkAutoApiCalls(): String = "{\"error\":\"not supported\"}"

        @JavascriptInterface
        fun pollAutoApiResult(): String = "{\"pending\":false}"

        @JavascriptInterface
        fun finishVkCalls(callIdsJson: String): Boolean = false
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
        } catch (_: Exception) { }
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
            } catch (_: Exception) {}
        }

        return ParsedConfig(peer, password, hashes)
    }
}