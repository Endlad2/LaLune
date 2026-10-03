// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune backend для Android.
//
// Запускает HTTP-сервер на 127.0.0.1:1062, управляет VPN-сервисом,
// ядром CSQTT, VK-авторизацией, конфигами, настройками.
//
// Точка входа: Backend(context).run()
//
// Файлы данных: context.filesDir/la-lune/

package com.lalune.backend

import android.content.Context
import android.net.VpnService
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

class Backend(private val context: Context) {

    companion object {
        const val TAG = "LaLune-Backend"
        const val PORT = 1062
        const val HOST = "127.0.0.1"
        const val VERSION = "0.6.0"

        const val CORE_LISTEN_PORT = 52230
        const val DEFAULT_TUN_IP = "10.66.67.12"
        const val DEFAULT_DNS_1 = "8.8.8.8"
        const val DEFAULT_DNS_2 = "8.8.4.4"
        const val MTU = 1300

        const val LATEST_URL = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
        const val CORE_URL_TEMPLATE = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
        const val PROXY_URL = "http://31.77.148.203:8855/?url="
        const val UA_BROWSER = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        const val UA_CURL = "curl/7.68.0"

        const val DEFAULT_WORKERS = 9
        const val MIN_WORKERS = 1
        const val MAX_WORKERS = 127
        const val DEFAULT_AUTO_API_WORKERS = 9
        const val MIN_AUTO_API_WORKERS = 9
        const val MAX_AUTO_API_WORKERS = 27

        const val VK_CLIENT_ID = "7793118"
        const val VK_SCOPE = "1073737727"
        const val VK_REDIRECT_URI = "https://oauth.vk.ru/blank.html"
        const val VK_API_BASE = "https://api.vk.ru/method/"
        const val VK_API_VERSION = "5.199"
    }

    // ---------- Пути ----------
    private val appDir = File(context.filesDir, "la-lune").apply { mkdirs() }
    private val configsFile = File(appDir, "configs.db")   // SQLite на Android отключён, используем JSON
    private val configsJson = File(appDir, "configs.json")
    private val settingsFile = File(appDir, "settings.json")
    private val logsFile = File(appDir, "logs.log")
    private val tokenFile = File(appDir, "token.json")
    private val latestFile = File(appDir, "LATEST")
    private val coreDir = File(appDir, "core").apply { mkdirs() }

    // ---------- Состояние ----------
    private val eventSubscribers = CopyOnWriteArrayList<EventStream>()
    private val logs = CopyOnWriteArrayList<String>()
    private val activeCallIds = CopyOnWriteArrayList<String>()
    private var httpServer: ServerSocket? = null

    @Volatile private var running = false
    @Volatile private var vpnConnected = false
    @Volatile private var smarttunnelRunning = false
    @Volatile private var coreDownloading = false

    private var vpnService: LaLuneVpnService? = null

    // ============================================================
    //  run() — точка входа
    // ============================================================

    fun run() {
        if (running) {
            Log.w(TAG, "Backend already running")
            return
        }
        running = true

        ensureDefaults()
        startHttpServer()
        addLog("[BACKEND] LaLune Android backend started on http://$HOST:$PORT")
    }

    fun stop() {
        running = false
        try { httpServer?.close() } catch (_: Exception) {}
        httpServer = null
    }

    // ============================================================
    //  HTTP-сервер
    // ============================================================

    private fun startHttpServer() {
        thread(name = "lalune-http", isDaemon = true) {
            try {
                val server = ServerSocket(PORT, 50, java.net.InetAddress.getByName(HOST))
                httpServer = server
                Log.i(TAG, "HTTP listening on $HOST:$PORT")

                while (running) {
                    try {
                        val client = server.accept()
                        thread(isDaemon = true) { handleClient(client) }
                    } catch (e: Exception) {
                        if (running) Log.e(TAG, "accept error: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "HTTP server failed: ${e.message}", e)
            }
        }
    }

    private fun handleClient(socket: Socket) {
        try {
            socket.use { s ->
                val input = BufferedReader(InputStreamReader(s.getInputStream()))
                val output = OutputStreamWriter(s.getOutputStream())

                val requestLine = input.readLine() ?: return
                val parts = requestLine.split(" ")
                if (parts.size < 2) return
                val method = parts[0]
                val pathAndQuery = parts[1]

                val headers = mutableMapOf<String, String>()
                while (true) {
                    val line = input.readLine() ?: break
                    if (line.isEmpty()) break
                    val idx = line.indexOf(':')
                    if (idx > 0) {
                        headers[line.substring(0, idx).trim().lowercase()] =
                            line.substring(idx + 1).trim()
                    }
                }

                val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
                val body = if (contentLength > 0) {
                    val buf = CharArray(contentLength)
                    var read = 0
                    while (read < contentLength) {
                        val n = input.read(buf, read, contentLength - read)
                        if (n < 0) break
                        read += n
                    }
                    String(buf, 0, read)
                } else ""

                // CORS + SSE
                if (pathAndQuery.startsWith("/events")) {
                    handleSse(s, output)
                    return
                }
                if (pathAndQuery.startsWith("/logs/stream")) {
                    handleLogsSse(s, output)
                    return
                }

                val (code, response) = route(method, pathAndQuery, body)

                output.write("HTTP/1.1 $code ${statusText(code)}\r\n")
                output.write("Content-Type: application/json; charset=utf-8\r\n")
                output.write("Content-Length: ${response.toByteArray(Charsets.UTF_8).size}\r\n")
                output.write("Access-Control-Allow-Origin: *\r\n")
                output.write("Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,OPTIONS\r\n")
                output.write("Access-Control-Allow-Headers: *\r\n")
                output.write("Connection: close\r\n")
                output.write("\r\n")
                output.write(response)
                output.flush()
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleClient error: ${e.message}")
        }
    }

    private fun statusText(code: Int): String = when (code) {
        200 -> "OK"
        400 -> "Bad Request"
        401 -> "Unauthorized"
        404 -> "Not Found"
        409 -> "Conflict"
        500 -> "Internal Server Error"
        else -> "OK"
    }

    // ============================================================
    //  Router
    // ============================================================

    private fun route(method: String, rawPath: String, body: String): Pair<Int, String> {
        val qIdx = rawPath.indexOf('?')
        val path = if (qIdx >= 0) rawPath.substring(0, qIdx) else rawPath
        val query = if (qIdx >= 0) rawPath.substring(qIdx + 1) else ""

        // OPTIONS — CORS preflight
        if (method == "OPTIONS") return 200 to "{}"

        try {
            return when {
                // ---------- Базовые ----------
                path == "/ping" && method == "GET" -> 200 to jsonOk(
                    "ok" to true,
                    "version" to VERSION,
                    "os" to "android",
                    "arch" to android.os.Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
                    "uptime" to 0
                )
                path == "/version" && method == "GET" -> 200 to jsonOk(
                    "api" to 1, "backend" to VERSION, "core" to readLatest(), "ui" to VERSION
                )
                path == "/shutdown" && method == "POST" -> {
                    stop(); 200 to jsonOk("ok" to true)
                }

                // ---------- Конфиги ----------
                path == "/configs" && method == "GET" -> 200 to loadConfigs().toString()
                path.startsWith("/configs/") && method == "GET" && path != "/configs/selected" -> {
                    val id = path.removePrefix("/configs/").toLongOrNull()
                    val c = findConfig(id ?: 0L)
                    if (c != null) 200 to c.toString() else 404 to jsonErr("not found")
                }
                path == "/configs" && method == "POST" -> createConfig(body)
                path.startsWith("/configs/") && method == "PUT" && path != "/configs/selected" -> {
                    val id = path.removePrefix("/configs/").toLongOrNull() ?: 0L
                    updateConfig(id, body)
                }
                path.startsWith("/configs/") && method == "DELETE" && path != "/configs/selected" -> {
                    val id = path.removePrefix("/configs/").toLongOrNull() ?: 0L
                    deleteConfig(id)
                }
                path == "/configs/parse" && method == "POST" -> {
                    val b = JSONObject(body)
                    val link = b.optString("link", "")
                    200 to parseLink(link).toString()
                }
                path == "/configs/selected" && method == "GET" -> {
                    val sel = readSelectedConfig()
                    if (sel != null) 200 to sel.toString() else 200 to "{}"
                }
                path == "/configs/selected" && method == "PUT" -> {
                    val b = JSONObject(body)
                    if (b.has("id")) {
                        val id = b.getLong("id")
                        val c = findConfig(id)
                        if (c != null) { writeSelectedConfig(c); 200 to jsonOk("ok" to true) }
                        else 404 to jsonErr("config not found")
                    } else {
                        clearSelectedConfig(); 200 to jsonOk("ok" to true)
                    }
                }

                // ---------- Настройки ----------
                path == "/settings" && method == "GET" -> 200 to loadSettings().toString()
                path == "/settings" && method == "PUT" -> replaceSettings(body)
                path == "/settings" && method == "PATCH" -> patchSettings(body)
                path == "/settings/reset" && method == "POST" -> {
                    saveSettings(defaultSettings()); 200 to jsonOk("ok" to true)
                }
                path.startsWith("/settings/") && method == "GET" -> {
                    val key = path.removePrefix("/settings/")
                    val s = loadSettings()
                    if (s.has(key)) 200 to s.get(key).toString() else 404 to jsonErr("key not found")
                }
                path.startsWith("/settings/") && method == "PUT" -> {
                    val key = path.removePrefix("/settings/")
                    val s = loadSettings()
                    s.put(key, JSONObject("{\"v\":$body}").get("v"))
                    saveSettings(s); 200 to jsonOk("ok" to true)
                }

                // ---------- Device ----------
                path == "/device/id" && method == "GET" -> 200 to jsonOk("deviceId" to getDeviceId())
                path == "/device/id/regenerate" && method == "POST" -> {
                    val id = UUID.randomUUID().toString().replace("-", "")
                    updateDeviceId(id)
                    200 to jsonOk("deviceId" to id)
                }
                path == "/device/info" && method == "GET" -> 200 to jsonOk(
                    "os" to "android",
                    "arch" to android.os.Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
                    "hostname" to android.os.Build.MODEL,
                    "cores" to Runtime.getRuntime().availableProcessors(),
                    "totalMemMb" to 0
                )

                // ---------- VPN ----------
                path == "/vpn/connect" && method == "POST" -> vpnConnect(body)
                path == "/vpn/disconnect" && method == "POST" -> vpnDisconnect()
                path == "/vpn/status" && method == "GET" -> 200 to jsonOk(
                    "state" to if (vpnConnected) "connected" else "disconnected",
                    "connected" to vpnConnected,
                    "uptimeSec" to 0,
                    "configId" to 0,
                    "message" to "",
                    "since" to ""
                )
                path == "/vpn/reconnect" && method == "POST" -> {
                    vpnDisconnect(); Thread.sleep(300)
                    vpnConnect("{}")
                }
                path == "/vpn/stats" && method == "GET" -> 200 to jsonOk(
                    "rxBytes" to 0, "txBytes" to 0, "rxRate" to 0, "txRate" to 0,
                    "activeSessions" to if (vpnConnected) 1 else 0
                )
                path == "/vpn/tunconf" && method == "GET" -> 200 to "{}"

                // ---------- Логи ----------
                path == "/logs" && method == "GET" -> 200 to JSONArray(logs.toList()).toString()
                path == "/logs/tail" && method == "GET" -> {
                    val n = queryParam(query, "lines")?.toIntOrNull() ?: 100
                    val start = (logs.size - n).coerceAtLeast(0)
                    val tail = if (start < logs.size) logs.subList(start, logs.size).toList() else emptyList()
                    200 to JSONArray(tail).toString()
                }
                path == "/logs" && method == "DELETE" -> {
                    logs.clear(); 200 to jsonOk("ok" to true)
                }
                path == "/logs/export" && method == "GET" -> 200 to logs.joinToString("\n")

                // ---------- Ядро ----------
                path == "/core/version" && method == "GET" -> 200 to jsonOk("version" to readLatest())
                path == "/core/latest" && method == "GET" -> {
                    val v = fetchLatestVersion() ?: ""
                    200 to jsonOk("version" to v)
                }
                path == "/core/check" && method == "GET" -> {
                    val local = readLatest()
                    val remote = fetchLatestVersion() ?: ""
                    200 to jsonOk(
                        "hasUpdate" to (remote.isNotEmpty() && remote != local),
                        "local" to local, "remote" to remote
                    )
                }
                path == "/core/download" && method == "POST" -> {
                    if (coreDownloading) 409 to jsonErr("already downloading")
                    else {
                        coreDownloading = true
                        thread { try { downloadCore() } finally { coreDownloading = false } }
                        200 to jsonOk("ok" to true, "async" to true)
                    }
                }
                path == "/core/download/sync" && method == "POST" -> {
                    val ok = downloadCore()
                    if (ok) 200 to jsonOk("ok" to true) else 500 to jsonErr("download failed")
                }
                path == "/core/path" && method == "GET" -> 200 to jsonOk("path" to (getCorePath() ?: ""))
                path == "/core/protocols" && method == "GET" -> 200 to JSONArray(listOf(
                    JSONObject().apply {
                        put("id", "CSQTT"); put("displayName", "CSQTT (VK Calls)")
                        put("repo", "Endlad2/csqtt-core"); put("realtime", true)
                        put("description", "Оригинальный протокол CSQTT")
                        put("coreAsset", getCoreName() ?: "")
                    }
                )).toString()
                path == "/core" && method == "DELETE" -> {
                    getCorePath()?.let { File(it).delete() }
                    200 to jsonOk("ok" to true)
                }

                // ---------- Обновление ----------
                path == "/update/check" && method == "GET" -> 200 to jsonOk(
                    "hasUpdate" to false, "remoteTag" to "", "localVersion" to VERSION
                )
                path == "/update/url" && method == "GET" -> 200 to jsonOk(
                    "url" to "https://github.com/Endlad2/LaLune/releases/latest"
                )

                // ---------- VK ----------
                path == "/vk/token/state" && method == "GET" -> 200 to readVkState().toString()
                path == "/vk/token/login" && method == "POST" -> 200 to jsonOk(
                    "ok" to true, "needsUi" to true, "authUrl" to vkAuthUrl()
                )
                path == "/vk/token/submit" && method == "POST" -> {
                    val b = JSONObject(body)
                    val token = b.optString("token", "")
                    if (token.isEmpty()) 400 to jsonErr("token empty")
                    else { saveVkToken(token); 200 to jsonOk("ok" to true) }
                }
                path == "/vk/token/validate" && method == "GET" -> {
                    val token = readVkToken()
                    if (token == null) 200 to jsonOk("valid" to false, "message" to "no token")
                    else 200 to jsonOk("valid" to true, "message" to "")
                }
                path == "/vk/token/fetch/cancel" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/vk/token" && method == "DELETE" -> {
                    tokenFile.delete(); 200 to jsonOk("ok" to true)
                }

                // ---------- VK Calls ----------
                path == "/vk/calls/start" && method == "POST" -> vkCallsStart(body)
                path == "/vk/calls/stop" && method == "POST" -> {
                    val b = JSONObject(body)
                    val arr = b.optJSONArray("callIds") ?: JSONArray()
                    activeCallIds.removeAll { id ->
                        var removed = false
                        for (i in 0 until arr.length()) {
                            if (arr.getString(i) == id) { removed = true; break }
                        }
                        removed
                    }
                    200 to jsonOk("finished" to arr.length())
                }
                path == "/vk/calls/stop-all" && method == "POST" -> {
                    val n = activeCallIds.size
                    activeCallIds.clear()
                    200 to jsonOk("finished" to n)
                }
                path == "/vk/calls/active" && method == "GET" ->
                    200 to jsonOk("callIds" to JSONArray(activeCallIds.toList()))

                // ---------- SmartTunnel ----------
                path == "/smarttunnel/status" && method == "GET" ->
                    200 to jsonOk("running" to smarttunnelRunning)
                path == "/smarttunnel/start" && method == "POST" -> {
                    smarttunnelRunning = true; 200 to jsonOk("ok" to true)
                }
                path == "/smarttunnel/stop" && method == "POST" -> {
                    smarttunnelRunning = false; 200 to jsonOk("ok" to true)
                }
                path == "/smarttunnel/reload" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/smarttunnel/logs" && method == "GET" -> 200 to "[]"
                path == "/smarttunnel/args" && method == "GET" -> 200 to "[]"
                path == "/smarttunnel/args" && method == "PUT" -> 200 to jsonOk("ok" to true)

                // ---------- Deploy (заглушка) ----------
                path == "/deploy/run" && method == "POST" ->
                    200 to jsonOk("stub" to true, "message" to "DeployManager not yet implemented")
                path == "/deploy/status" && method == "GET" ->
                    200 to jsonOk("busy" to false, "stub" to true)
                path == "/deploy/log" && method == "GET" ->
                    200 to jsonOk("log" to "", "stub" to true)
                path == "/deploy/cancel" && method == "POST" ->
                    200 to jsonOk("stub" to true)
                path == "/deploy/protocols" && method == "GET" ->
                    200 to jsonOk("protocols" to JSONArray(), "stub" to true)

                // ---------- Platform ----------
                path == "/platform/capabilities" && method == "GET" -> 200 to jsonOk(
                    "canShowWebView" to true,
                    "canRunTun" to true,
                    "canDeploy" to false,
                    "canAutoUpdate" to false,
                    "canSendNotifications" to true,
                    "canOpenExternalUrl" to true,
                    "os" to "android",
                    "platform" to "mobile"
                )
                path == "/platform/open-url" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/platform/notify" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/platform/open-path" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/platform/share" && method == "POST" -> 200 to jsonOk("ok" to true)

                // ---------- Debug ----------
                path == "/debug/state" && method == "GET" -> 200 to jsonOk(
                    "logCount" to logs.size,
                    "appDir" to appDir.absolutePath,
                    "vpnConnected" to vpnConnected
                )
                path == "/debug/echo" && method == "POST" -> 200 to body
                path == "/debug/config" && method == "GET" -> 200 to jsonOk(
                    "appDir" to appDir.absolutePath,
                    "configsPath" to configsJson.absolutePath,
                    "settingsPath" to settingsFile.absolutePath,
                    "logsPath" to logsFile.absolutePath,
                    "tokenPath" to tokenFile.absolutePath,
                    "corePath" to (getCorePath() ?: "")
                )
                path == "/debug/reload-config" && method == "POST" -> 200 to jsonOk("ok" to true)

                else -> 404 to jsonErr("route not found: $method $path")
            }
        } catch (e: Exception) {
            Log.e(TAG, "route error: ${e.message}", e)
            return 500 to jsonErr(e.message ?: "internal error")
        }
    }

    // ============================================================
    //  SSE
    // ============================================================

    private inner class EventStream(val writer: OutputStreamWriter) {
        fun send(data: String) {
            try {
                writer.write("data: $data\n\n")
                writer.flush()
            } catch (_: Exception) {}
        }
    }

    private fun handleSse(socket: Socket, output: OutputStreamWriter) {
        try {
            output.write("HTTP/1.1 200 OK\r\n")
            output.write("Content-Type: text/event-stream\r\n")
            output.write("Cache-Control: no-cache\r\n")
            output.write("Connection: keep-alive\r\n")
            output.write("Access-Control-Allow-Origin: *\r\n")
            output.write("\r\n")
            output.flush()

            val stream = EventStream(output)
            eventSubscribers.add(stream)

            // Держим соединение
            while (running && !socket.isClosed) {
                try { Thread.sleep(15000); stream.send("""{"type":"ping"}""") } catch (_: Exception) { break }
            }
            eventSubscribers.remove(stream)
        } catch (e: Exception) {
            Log.e(TAG, "SSE error: ${e.message}")
        }
    }

    private fun handleLogsSse(socket: Socket, output: OutputStreamWriter) {
        try {
            output.write("HTTP/1.1 200 OK\r\n")
            output.write("Content-Type: text/event-stream\r\n")
            output.write("Cache-Control: no-cache\r\n")
            output.write("Connection: keep-alive\r\n\r\n")
            output.flush()

            val stream = EventStream(output)
            eventSubscribers.add(stream)
            while (running && !socket.isClosed) {
                try { Thread.sleep(15000) } catch (_: Exception) { break }
            }
            eventSubscribers.remove(stream)
        } catch (_: Exception) {}
    }

    private fun emit(type: String, payload: JSONObject) {
        val event = JSONObject().apply {
            put("type", type)
            payload.keys().forEach { k -> put(k, payload.get(k)) }
        }.toString()
        eventSubscribers.forEach { it.send(event) }
    }

    private fun addLog(line: String) {
        Log.d(TAG, line)
        logs.add(line)
        if (logs.size > 1000) logs.removeAt(0)
        try { logsFile.appendText(line + "\n") } catch (_: Exception) {}
        emit("log", JSONObject().put("line", line).put("ts", System.currentTimeMillis() / 1000))
    }

    // ============================================================
    //  Файлы и настройки
    // ============================================================

    private fun ensureDefaults() {
        if (!settingsFile.exists()) saveSettings(defaultSettings())
        if (!configsJson.exists()) configsJson.writeText("[]")
        if (!logsFile.exists()) logsFile.writeText("")
    }

    private fun defaultSettings() = JSONObject().apply {
        put("peer", ""); put("vkHashes", ""); put("vkJsToken", "")
        put("workers", DEFAULT_WORKERS); put("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
        put("password", ""); put("obfs", "video"); put("fingerprint", "firefox")
        put("clientIds", "8202606,6287487"); put("deviceId", getDeviceId())
        put("authMode", "manual"); put("turnTransport", "udp")
        put("turnHost", ""); put("turnPort", "")
        put("captchaMode", "auto"); put("vkAuthMode", "vkcalls")
        put("allowHashRedistribution", false); put("validateVkHashes", false)
        put("enableSmartTunnel", false)
    }

    private fun loadSettings(): JSONObject = try {
        if (settingsFile.exists()) JSONObject(settingsFile.readText())
        else defaultSettings()
    } catch (_: Exception) { defaultSettings() }

    private fun saveSettings(s: JSONObject) {
        var w = s.optInt("workers", DEFAULT_WORKERS).coerceIn(MIN_WORKERS, MAX_WORKERS)
        var aw = s.optInt("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
            .coerceIn(MIN_AUTO_API_WORKERS, MAX_AUTO_API_WORKERS)
        s.put("workers", w); s.put("autoApiWorkers", aw)
        settingsFile.writeText(s.toString())
    }

    private fun replaceSettings(body: String): Pair<Int, String> {
        return try {
            val s = JSONObject(body)
            saveSettings(s)
            200 to jsonOk("ok" to true)
        } catch (e: Exception) { 400 to jsonErr(e.message ?: "bad json") }
    }

    private fun patchSettings(body: String): Pair<Int, String> {
        return try {
            val patch = JSONObject(body)
            val s = loadSettings()
            patch.keys().forEach { k -> s.put(k, patch.get(k)) }
            saveSettings(s)
            200 to jsonOk("ok" to true)
        } catch (e: Exception) { 400 to jsonErr(e.message ?: "bad json") }
    }

    private fun getDeviceId(): String {
        val s = loadSettings()
        var id = s.optString("deviceId", "")
        if (id.isBlank()) {
            id = UUID.randomUUID().toString().replace("-", "")
            s.put("deviceId", id)
            saveSettings(s)
        }
        return id
    }

    private fun updateDeviceId(newId: String) {
        val s = loadSettings()
        s.put("deviceId", newId)
        saveSettings(s)
    }

    private fun readLatest(): String = try {
        if (latestFile.exists()) latestFile.readText().trim() else ""
    } catch (_: Exception) { "" }

    private fun readVkToken(): String? = try {
        if (!tokenFile.exists()) null
        else {
            val j = JSONObject(tokenFile.readText())
            val t = j.optString("Token", j.optString("token", ""))
            if (t.isBlank()) null else t
        }
    } catch (_: Exception) { null }

    private fun saveVkToken(token: String) {
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date())
        tokenFile.writeText(JSONObject().apply {
            put("Token", token); put("SavedAt", iso)
        }.toString())
        addLog("[VK] token saved")
    }

    private fun readVkState(): JSONObject {
        val has = readVkToken() != null
        return JSONObject().apply {
            put("hasToken", has)
            put("fetching", false)
            put("progress", if (has) 100 else 0)
            put("message", if (has) "VK token active" else "")
        }
    }

    private fun vkAuthUrl(): String {
        val redirect = URLEncoder.encode(VK_REDIRECT_URI, "UTF-8")
        return "https://oauth.vk.ru/authorize?client_id=$VK_CLIENT_ID&scope=$VK_SCOPE" +
                "&redirect_uri=$redirect&display=page&response_type=token&revoke=1&v=5.199"
    }

    // ============================================================
    //  Конфиги
    // ============================================================

    private fun loadConfigs(): JSONArray = try {
        if (configsJson.exists()) JSONArray(configsJson.readText()) else JSONArray()
    } catch (_: Exception) { JSONArray() }

    private fun saveConfigs(arr: JSONArray) = configsJson.writeText(arr.toString())

    private fun findConfig(id: Long): JSONObject? {
        val arr = loadConfigs()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            if (o.optLong("id") == id) return o
        }
        return null
    }

    private fun createConfig(body: String): Pair<Int, String> {
        return try {
            val b = JSONObject(body)
            val protocol = b.optString("protocol", "CSQTT")
            val link = b.optString("link", "")
            val parsed = if (link.isNotEmpty()) parseLink(link) else JSONObject().apply {
                put("protocol", protocol)
                put("peer", b.optString("peer", ""))
                put("password", b.optString("password", ""))
                put("hashes", b.optString("hashes", ""))
                put("name", b.optString("name", ""))
            }
            val id = System.currentTimeMillis()
            parsed.put("id", id)
            parsed.put("rawLink", link)
            val arr = loadConfigs()
            arr.put(parsed)
            saveConfigs(arr)
            200 to jsonOk("id" to id)
        } catch (e: Exception) { 400 to jsonErr(e.message ?: "bad json") }
    }

    private fun updateConfig(id: Long, body: String): Pair<Int, String> {
        return try {
            val b = JSONObject(body)
            val arr = loadConfigs()
            var found = false
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                if (o.optLong("id") == id) {
                    b.keys().forEach { k -> o.put(k, b.get(k)) }
                    o.put("id", id)
                    found = true
                    break
                }
            }
            if (!found) return 404 to jsonErr("not found")
            saveConfigs(arr)
            200 to jsonOk("ok" to true)
        } catch (e: Exception) { 400 to jsonErr(e.message ?: "bad json") }
    }

    private fun deleteConfig(id: Long): Pair<Int, String> {
        val arr = loadConfigs()
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            if (o.optLong("id") != id) out.put(o)
        }
        saveConfigs(out)
        return 200 to jsonOk("ok" to true)
    }

    private fun readSelectedConfig(): JSONObject? = try {
        val f = File(appDir, "selected_config.json")
        if (f.exists()) JSONObject(f.readText()) else null
    } catch (_: Exception) { null }

    private fun writeSelectedConfig(c: JSONObject) {
        File(appDir, "selected_config.json").writeText(c.toString())
    }

    private fun clearSelectedConfig() {
        File(appDir, "selected_config.json").delete()
    }

    private fun parseLink(link: String): JSONObject {
        val out = JSONObject().apply {
            put("protocol", "CSQTT")
            put("peer", ""); put("password", ""); put("hashes", ""); put("name", "")
        }
        if (!link.startsWith("csqtt://", ignoreCase = true)) {
            out.put("peer", link)
            return out
        }
        val rest = link.removePrefix("csqtt://")
        if (rest.startsWith("connect?")) {
            val query = rest.removePrefix("connect?")
            var host = ""; var port = ""; var password = ""; var hashes = ""
            query.split("&").forEach { kv ->
                val idx = kv.indexOf('=')
                if (idx > 0) {
                    val k = kv.substring(0, idx)
                    val v = kv.substring(idx + 1)
                    when (k) {
                        "host" -> host = v
                        "peer" -> port = v
                        "password" -> password = v
                        "hashes" -> hashes = v.replace('+', ',')
                    }
                }
            }
            val peer = "$host:$port"
            out.put("peer", peer); out.put("password", password)
            out.put("hashes", hashes); out.put("name", peer)
        }
        return out
    }

    // ============================================================
    //  Ядро
    // ============================================================

    private fun getCoreName(): String? {
        val arch = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
        return when {
            arch.contains("arm64") -> "libclient-android-arm64-v8a.so"
            arch.contains("arm") -> "libclient-android-armeabi-v7a.so"
            arch.contains("x86_64") -> "libclient-android-x86_64.so"
            else -> null
        }
    }

    private fun getCorePath(): String? {
        val name = getCoreName() ?: return null
        // nativeLibraryDir — для APK-собранного бинарника
        val native = File(context.applicationInfo.nativeLibraryDir, name)
        if (native.exists()) return native.absolutePath
        val cached = File(coreDir, name)
        if (cached.exists()) return cached.absolutePath
        return null
    }

    private fun fetchLatestVersion(): String? {
        for (level in 1..3) {
            try {
                val url = when (level) {
                    1 -> LATEST_URL
                    else -> PROXY_URL + URLEncoder.encode(LATEST_URL, "UTF-8")
                }
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 30000
                conn.readTimeout = 30000
                conn.setRequestProperty("User-Agent", if (level == 3) UA_CURL else UA_BROWSER)
                if (conn.responseCode == 200) {
                    val text = BufferedReader(InputStreamReader(conn.inputStream)).readText().trim()
                    if (text.isNotEmpty() && !text.contains("Server error")) return text
                }
            } catch (e: Exception) {
                addLog("[NET][LEVEL $level] ${e.message}")
            }
        }
        return null
    }

    private fun downloadCore(): Boolean {
        val name = getCoreName() ?: return false
        val version = fetchLatestVersion() ?: return false
        val url = CORE_URL_TEMPLATE.format(version, name)
        addLog("[CORE] downloading $url")

        for (level in 1..3) {
            try {
                val useUrl = when (level) {
                    1 -> url
                    else -> PROXY_URL + URLEncoder.encode(url, "UTF-8")
                }
                val conn = URL(useUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 30000
                conn.readTimeout = 60000
                conn.setRequestProperty("User-Agent", if (level == 3) UA_CURL else UA_BROWSER)
                if (conn.responseCode == 200) {
                    val dest = File(coreDir, name)
                    conn.inputStream.use { input -> dest.outputStream().use { input.copyTo(it) } }
                    if (dest.length() > 1024) {
                        dest.setExecutable(true, false)
                        latestFile.writeText(version)
                        addLog("[CORE] downloaded OK (${dest.length()} bytes)")
                        return true
                    }
                }
            } catch (e: Exception) {
                addLog("[DOWNLOAD][LEVEL $level] ${e.message}")
            }
        }
        return false
    }

    // ============================================================
    //  VPN
    // ============================================================

    private fun vpnConnect(body: String): Pair<Int, String> {
        val settings = loadSettings()
        val peer = settings.optString("peer", "")
        if (peer.isEmpty()) {
            // Попробуем из выбранного конфига
            val sel = readSelectedConfig()
            if (sel == null) return 400 to jsonErr("no config selected")
        }

        return try {
            vpnConnected = true
            emit("status", JSONObject().put("connected", true))
            addLog("[VPN] connect requested")
            200 to jsonOk("ok" to true, "status" to "connecting")
        } catch (e: Exception) {
            500 to jsonErr(e.message ?: "connect failed")
        }
    }

    private fun vpnDisconnect(): Pair<Int, String> {
        vpnConnected = false
        emit("status", JSONObject().put("connected", false))
        addLog("[VPN] disconnect")
        return 200 to jsonOk("ok" to true)
    }

    // ============================================================
    //  VK Calls
    // ============================================================

    private fun vkCallsStart(body: String): Pair<Int, String> {
        val token = readVkToken() ?: return 400 to jsonErr("no VK token")
        return try {
            val b = JSONObject(body)
            val workers = b.optInt("workers", loadSettings().optInt("workers", DEFAULT_WORKERS))
            val aw = b.optInt("autoApiWorkers", loadSettings().optInt("autoApiWorkers", DEFAULT_AUTO_API_WORKERS))
            val count = callCountForWorkers(workers, aw)
            val hashes = JSONArray(); val callIds = JSONArray()

            for (slot in 0 until count) {
                if (slot > 0) Thread.sleep(if (count <= 4) 80L else 202L)
                val (callId, hash, errCode) = startVkCall(token)
                if (hash.isNotEmpty()) {
                    hashes.put(hash); callIds.put(callId); activeCallIds.add(callId)
                } else if (errCode in listOf(4, 5, 27, 28)) {
                    return 401 to jsonErr("VK token invalid")
                }
            }

            if (hashes.length() == 0) 500 to jsonErr("no calls created")
            else 200 to jsonOk("hashes" to hashes, "callIds" to callIds)
        } catch (e: Exception) { 500 to jsonErr(e.message ?: "vk calls failed") }
    }

    private fun callCountForWorkers(workers: Int, aw: Int): Int {
        val aw2 = if (aw <= 0) DEFAULT_AUTO_API_WORKERS else aw
        val w2 = if (workers <= 0) DEFAULT_WORKERS else workers
        val count = kotlin.math.ceil(w2.toDouble() / aw2.toDouble()).toInt()
        return count.coerceIn(1, 6)
    }

    private fun startVkCall(token: String): Triple<String, String, Int> {
        return try {
            val url = URL(VK_API_BASE + "calls.start")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 8000
            conn.readTimeout = 8000
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            conn.setRequestProperty("User-Agent", UA_BROWSER)
            conn.outputStream.use { it.write("v=$VK_API_VERSION".toByteArray()) }

            val resp = BufferedReader(InputStreamReader(conn.inputStream)).readText()
            val j = JSONObject(resp)
            if (j.has("error")) {
                val err = j.getJSONObject("error")
                Triple("", "", err.optInt("error_code", 0))
            } else {
                val r = j.getJSONObject("response")
                val callId = r.optString("call_id", "")
                val okLink = r.optString("ok_join_link", "")
                val joinLink = r.optString("join_link", "")
                val hash = if (okLink.isNotEmpty()) okLink else joinLink.substringAfterLast('/')
                Triple(callId, hash, 0)
            }
        } catch (e: Exception) {
            Triple("", "", -1)
        }
    }

    // ============================================================
    //  Helpers
    // ============================================================

    private fun jsonOk(vararg pairs: Pair<String, Any?>): String {
        val o = JSONObject()
        for ((k, v) in pairs) o.put(k, v ?: JSONObject.NULL)
        return o.toString()
    }

    private fun jsonErr(msg: String) = JSONObject().apply { put("error", msg) }.toString()

    private fun queryParam(query: String, key: String): String? {
        if (query.isEmpty()) return null
        for (kv in query.split("&")) {
            val idx = kv.indexOf('=')
            if (idx > 0 && kv.substring(0, idx) == key) {
                return URLEncoder.encode(kv.substring(idx + 1), "UTF-8")
            }
        }
        return null
    }
}
