// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune backend для Android.
//
// Device ID используется только для выбранного ядра CSQTT 2.1.9.
// csqtt:// парсится: csqtt-link (ProcessBuilder) → Lua → нативный.
// SOCKS5 слушает рандомный свободный порт (не 1080).

package com.lalune.lalune

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

class Backend(private val context: Context) {

    companion object {
        const val TAG = "LaLune-Backend"
        const val PORT = 1062
        const val HOST = "127.0.0.1"
        const val VERSION = "0.6.0"

        const val DEFAULT_WORKERS = 9
        const val MIN_WORKERS = 1
        const val MAX_WORKERS = 127
        const val DEFAULT_AUTO_API_WORKERS = 9
        const val MIN_AUTO_API_WORKERS = 9
        const val MAX_AUTO_API_WORKERS = 27

        const val VK_API_BASE = "https://api.vk.ru/method/"
        const val VK_API_VERSION = "5.199"

        const val REQ_VPN = 101

        const val CORE_PREFIX = "[CORE] "

        const val PROTO_CSQTT = "CSQTT"
        const val PROTO_CSQTT_219 = "CSQTT 2.1.9"
        const val PROTO_CSQTT_251 = "CSQTT 2.5.1"
        const val PROTO_PAPERFLUX = "PaperFlux"
    }

    private val appDir = File(context.filesDir, "la-lune").apply { mkdirs() }
    private val configsJson = File(appDir, "configs.json")
    private val settingsFile = File(appDir, "settings.json")
    private val deviceIdFile = File(appDir, "device_id.json")
    private val logsFile = File(appDir, "logs.log")
    private val tokenFile = File(appDir, "token.json")
    private val selectedConfigFile = File(appDir, "selected_config.json")

    private val eventSubscribers = CopyOnWriteArrayList<EventStream>()
    private val logs = CopyOnWriteArrayList<String>()
    private val activeCallIds = CopyOnWriteArrayList<String>()
    private var httpServer: ServerSocket? = null

    @Volatile private var running = false
    @Volatile private var vpnConnected = false
    @Volatile private var smarttunnelRunning = false
    @Volatile private var coreDownloading = false

    @Volatile private var vkLoginInProgress = false
    @Volatile private var vkLoginMessage = ""

    /** Порт SOCKS5 (0 = не запущен). */
    @Volatile var socks5Port: Int = 0
        private set

    private var activity: Activity? = null
    private var currentVkFetcher: VkWebViewFetcher? = null
    private var coreManager: CoreManager? = null
    private var socks5Server: Socks5Server? = null
    private var luaRuntime: LuaRuntime? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private val vpnStatusReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val connected = intent?.getBooleanExtra(
                LaLuneVpnService.EXTRA_CONNECTED, false
            ) ?: false
            vpnConnected = connected
            emit("status", JSONObject().put("connected", connected))
        }
    }

    fun attachActivity(a: Activity) { activity = a }

    fun run() {
        if (running) { Log.w(TAG, "Backend already running"); return }
        running = true
        coreManager = CoreManager(context)

        ensureDefaults()
        registerVpnReceiver()
        startLuaRuntime()

        CsqttLink.ensureAvailable(context)

        startHttpServer()
        addLog("[BACKEND] LaLune Android backend started on http://$HOST:$PORT")
    }

    fun stop() {
        running = false
        stopSocks5()
        luaRuntime?.destroy()
        luaRuntime = null
        try { httpServer?.close() } catch (_: Exception) {}
        httpServer = null
        try { unregisterVpnReceiver() } catch (_: Exception) {}
    }

    private fun startLuaRuntime() {
        try {
            luaRuntime = LuaRuntime(
                context = context,
                appDir = appDir,
                settingsProvider = { loadSettings() },
                settingsSetter = { key, value ->
                    val s = loadSettings()
                    s.put(key, value ?: JSONObject.NULL)
                    saveSettings(s)
                },
                logFn = { line -> addLog(line) },
                logsFn = { logs.toList() },
                vkTokenFn = { readVkToken() },
                vpnRunningFn = { vpnConnected },
            ).also { it.init() }
        } catch (e: Exception) {
            Log.e(TAG, "[LUA] init failed: ${e.message}", e)
            addLog("[LUA] init failed: ${e.message}")
            luaRuntime = null
        }
    }

    private fun registerVpnReceiver() {
        val filter = IntentFilter(LaLuneVpnService.ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(vpnStatusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(vpnStatusReceiver, filter)
        }
    }

    private fun unregisterVpnReceiver() {
        try { context.unregisterReceiver(vpnStatusReceiver) } catch (_: Exception) {}
    }

    // ============================================================
    //  HTTP
    // ============================================================

    private fun startHttpServer() {
        thread(name = "lalune-http", isDaemon = true) {
            try {
                val server = ServerSocket(PORT, 50, InetAddress.getByName(HOST))
                httpServer = server
                Log.i(TAG, "HTTP listening on $HOST:$PORT")
                while (running) {
                    try {
                        val client = server.accept()
                        thread(isDaemon = true) { handleClient(client) }
                    } catch (e: Exception) {
                        if (running) Log.e(TAG, "accept: ${e.message}")
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
                    if (idx > 0) headers[line.substring(0, idx).trim().lowercase()] =
                        line.substring(idx + 1).trim()
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

                if (pathAndQuery.startsWith("/events")) { handleSse(s, output); return }
                if (pathAndQuery.startsWith("/logs/stream")) { handleLogsSse(s, output); return }

                val (code, response) = route(method, pathAndQuery, body)
                val bytes = response.toByteArray(Charsets.UTF_8)
                output.write("HTTP/1.1 $code ${statusText(code)}\r\n")
                output.write("Content-Type: application/json; charset=utf-8\r\n")
                output.write("Content-Length: ${bytes.size}\r\n")
                output.write("Access-Control-Allow-Origin: *\r\n")
                output.write("Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,OPTIONS\r\n")
                output.write("Access-Control-Allow-Headers: *\r\n")
                output.write("Connection: close\r\n\r\n")
                output.write(response)
                output.flush()
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleClient: ${e.message}")
        }
    }

    private fun statusText(code: Int): String = when (code) {
        200 -> "OK"; 400 -> "Bad Request"; 401 -> "Unauthorized"
        404 -> "Not Found"; 409 -> "Conflict"; 500 -> "Internal Server Error"
        else -> "OK"
    }

    // ============================================================
    //  Router
    // ============================================================

    private fun route(method: String, rawPath: String, body: String): Pair<Int, String> {
        val qIdx = rawPath.indexOf('?')
        val path = if (qIdx >= 0) rawPath.substring(0, qIdx) else rawPath
        val query = if (qIdx >= 0) rawPath.substring(qIdx + 1) else ""

        if (method == "OPTIONS") return 200 to "{}"

        try {
            return when {
                path == "/ping" && method == "GET" -> 200 to jsonOk(
                    "ok" to true, "version" to VERSION, "os" to "android",
                    "arch" to android.os.Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
                    "hostname" to android.os.Build.MODEL,
                    "platform" to "android",
                    "uptime" to 0,
                    "socks5Port" to socks5Port
                )
                path == "/version" && method == "GET" -> 200 to jsonOk(
                    "api" to 1, "backend" to VERSION,
                    "core" to (coreManager?.readLatest() ?: ""), "ui" to VERSION
                )
                path == "/shutdown" && method == "POST" -> { stop(); 200 to jsonOk("ok" to true) }

                path == "/configs" && method == "GET" -> 200 to loadConfigs().toString()
                path == "/configs/parse" && method == "POST" -> {
                    val b = JSONObject(body)
                    val link = b.optString("link", "")
                    val protocol = b.optString("protocol", PROTO_CSQTT)
                    Log.i(TAG, "[API] POST /configs/parse link_len=${link.length} protocol=$protocol")
                    val parsed = parseLink(link, protocol)
                    Log.i(TAG, "[API] /configs/parse OK: peer=${parsed.optString("peer")}")
                    200 to parsed.toString()
                }
                path == "/configs/selected" && method == "GET" -> {
                    val sel = readSelectedConfig()
                    if (sel != null) 200 to sel.toString() else 200 to "{}"
                }
                path == "/configs/selected" && method == "PUT" -> {
                    val b = JSONObject(body)
                    if (b.has("id")) {
                        val c = findConfig(b.getLong("id"))
                        if (c != null) { writeSelectedConfig(c); 200 to jsonOk("ok" to true) }
                        else 404 to jsonErr("config not found")
                    } else { clearSelectedConfig(); 200 to jsonOk("ok" to true) }
                }
                path == "/configs" && method == "POST" -> createConfig(body)
                path.startsWith("/configs/") && method == "GET" && path != "/configs/selected" -> {
                    val id = path.removePrefix("/configs/").toLongOrNull() ?: 0L
                    val c = findConfig(id)
                    if (c != null) 200 to c.toString() else 404 to jsonErr("not found")
                }
                path.startsWith("/configs/") && method == "PUT" && path != "/configs/selected" -> {
                    val id = path.removePrefix("/configs/").toLongOrNull() ?: 0L
                    updateConfig(id, body)
                }
                path.startsWith("/configs/") && method == "DELETE" && path != "/configs/selected" -> {
                    val id = path.removePrefix("/configs/").toLongOrNull() ?: 0L
                    deleteConfig(id)
                }

                path == "/apps/installed" && method == "GET" -> {
                    val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val activities = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        context.packageManager.queryIntentActivities(
                            launcherIntent,
                            android.content.pm.PackageManager.ResolveInfoFlags.of(0)
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        context.packageManager.queryIntentActivities(launcherIntent, 0)
                    }
                    val apps = JSONArray()
                    activities
                        .mapNotNull { info ->
                            val packageName = info.activityInfo?.packageName ?: return@mapNotNull null
                            val label = info.loadLabel(context.packageManager)?.toString() ?: packageName
                            JSONObject().put("packageName", packageName).put("label", label)
                        }
                        .distinctBy { it.optString("packageName") }
                        .sortedBy { it.optString("label").lowercase(Locale.ROOT) }
                        .forEach { apps.put(it) }
                    200 to apps.toString()
                }
                path == "/device/id" && method == "GET" -> 200 to JSONObject().put("deviceId", ensureDeviceId()).toString()
                path == "/device/id/regenerate" && method == "POST" -> {
                    val id = java.util.UUID.randomUUID().toString()
                    writeDeviceId(id)
                    val settings = loadSettings().put("deviceId", id)
                    saveSettings(settings)
                    200 to JSONObject().put("deviceId", id).toString()
                }
                path == "/settings" && method == "GET" -> 200 to loadSettings().toString()
                path == "/settings" && method == "PUT" -> replaceSettings(body)
                path == "/settings" && method == "PATCH" -> patchSettings(body)
                path == "/settings/reset" && method == "POST" -> {
                    saveSettings(defaultSettings()); 200 to jsonOk("ok" to true)
                }
                path.startsWith("/settings-for/") && method == "GET" -> {
                    val proto = path.removePrefix("/settings-for/")
                    200 to settingsForProto(proto).toString()
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

                path == "/device/info" && method == "GET" -> 200 to jsonOk(
                    "os" to "android", "arch" to android.os.Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
                    "hostname" to android.os.Build.MODEL,
                    "deviceId" to ensureDeviceId(),
                    "cores" to Runtime.getRuntime().availableProcessors(),
                    "totalMemMb" to 0
                )

                path == "/vpn/connect" && method == "POST" -> vpnConnect(body)
                path == "/vpn/disconnect" && method == "POST" -> vpnDisconnect()
                path == "/vpn/status" && method == "GET" -> 200 to jsonOk(
                    "state" to if (vpnConnected) "connected" else "disconnected",
                    "connected" to vpnConnected, "uptimeSec" to 0,
                    "configId" to 0, "message" to "", "since" to "",
                    "socks5Port" to socks5Port
                )
                path == "/vpn/reconnect" && method == "POST" -> {
                    vpnDisconnect(); Thread.sleep(300); vpnConnect("{}")
                }
                path == "/vpn/stats" && method == "GET" -> 200 to jsonOk(
                    "rxBytes" to 0, "txBytes" to 0, "rxRate" to 0, "txRate" to 0,
                    "activeSessions" to if (vpnConnected) 1 else 0,
                    "socks5Port" to socks5Port
                )
                path == "/vpn/tunconf" && method == "GET" -> 200 to "{}"

                path == "/logs" && method == "GET" ->
                    200 to JSONArray(filterLogs(logs.toList(), queryParam(query, "source"))).toString()
                path == "/logs/tail" && method == "GET" -> {
                    val n = queryParam(query, "lines")?.toIntOrNull() ?: 100
                    val filtered = filterLogs(logs.toList(), queryParam(query, "source"))
                    val start = (filtered.size - n).coerceAtLeast(0)
                    val tail = if (start < filtered.size) filtered.subList(start, filtered.size) else emptyList()
                    200 to JSONArray(tail).toString()
                }
                path == "/logs" && method == "DELETE" -> { logs.clear(); 200 to jsonOk("ok" to true) }
                path == "/logs/export" && method == "GET" ->
                    200 to filterLogs(logs.toList(), queryParam(query, "source")).joinToString("\n")

                path == "/core/protocols" && method == "GET" -> 200 to protocolsJson().toString()

                path.startsWith("/core/") && method == "GET" -> routeCore(method, path.removePrefix("/core/"))
                path.startsWith("/core/") && method == "POST" -> routeCore(method, path.removePrefix("/core/"))
                path.startsWith("/core/") && method == "DELETE" -> routeCore(method, path.removePrefix("/core/"))

                path == "/update/check" && method == "GET" -> 200 to jsonOk(
                    "hasUpdate" to false, "remoteTag" to "", "localVersion" to VERSION
                )
                path == "/update/url" && method == "GET" -> 200 to jsonOk(
                    "url" to "https://github.com/Endlad2/LaLune/releases/latest"
                )

                path == "/vk/token/state" && method == "GET" -> 200 to readVkState().toString()
                path == "/vk/token/login" && method == "POST" -> vkLogin()
                path == "/vk/token/submit" && method == "POST" -> {
                    val b = JSONObject(body)
                    val token = b.optString("token", "")
                    if (token.isEmpty()) 400 to jsonErr("token empty")
                    else { saveVkToken(token); 200 to jsonOk("ok" to true) }
                }
                path == "/vk/token/validate" && method == "GET" -> 200 to jsonOk(
                    "valid" to (readVkToken() != null), "message" to ""
                )
                path == "/vk/token/raw" && method == "GET" -> {
                    val token = readVkToken() ?: ""
                    200 to jsonOk("token" to token)
                }
                path == "/vk/token/fetch/cancel" && method == "POST" -> {
                    mainHandler.post { currentVkFetcher?.cancel() }
                    200 to jsonOk("ok" to true)
                }
                path == "/vk/token" && method == "DELETE" -> {
                    tokenFile.delete(); 200 to jsonOk("ok" to true)
                }

                path == "/vk/calls/start" && method == "POST" -> vkCallsStart(body)
                path == "/vk/calls/stop" && method == "POST" -> {
                    val b = JSONObject(body); val arr = b.optJSONArray("callIds") ?: JSONArray()
                    activeCallIds.removeAll { id ->
                        var removed = false
                        for (i in 0 until arr.length()) if (arr.getString(i) == id) { removed = true; break }
                        removed
                    }
                    200 to jsonOk("finished" to arr.length())
                }
                path == "/vk/calls/stop-all" && method == "POST" -> {
                    val n = activeCallIds.size; activeCallIds.clear()
                    200 to jsonOk("finished" to n)
                }
                path == "/vk/calls/active" && method == "GET" ->
                    200 to jsonOk("callIds" to JSONArray(activeCallIds.toList()))

                path == "/smarttunnel/status" && method == "GET" ->
                    200 to jsonOk(
                        "running" to smarttunnelRunning,
                        "luaAvailable" to (luaRuntime != null),
                        "csqttLinkAvailable" to (CsqttLink.ensureAvailable(context) != null),
                    )
                path == "/smarttunnel/start" && method == "POST" -> {
                    smarttunnelRunning = true
                    luaRuntime?.smarttunnelRunning = true
                    luaRuntime?.onConnect()
                    200 to jsonOk("ok" to true)
                }
                path == "/smarttunnel/stop" && method == "POST" -> {
                    smarttunnelRunning = false
                    luaRuntime?.smarttunnelRunning = false
                    luaRuntime?.onDisconnect()
                    200 to jsonOk("ok" to true)
                }
                path == "/smarttunnel/reload" && method == "POST" -> {
                    luaRuntime?.destroy()
                    startLuaRuntime()
                    200 to jsonOk("ok" to true, "luaAvailable" to (luaRuntime != null))
                }
                path == "/smarttunnel/logs" && method == "GET" -> {
                    val filtered = logs.filter {
                        it.startsWith("[SMART-TUNNEL]") || it.startsWith("[LUA]") ||
                            it.startsWith("[CSQTT-LINK]")
                    }
                    200 to JSONArray(filtered).toString()
                }
                path == "/smarttunnel/args" && method == "GET" -> 200 to "[]"
                path == "/smarttunnel/args" && method == "PUT" -> 200 to jsonOk("ok" to true)

                path == "/deploy/run" && method == "POST" ->
                    200 to jsonOk("stub" to true, "message" to "DeployManager not yet implemented")
                path == "/deploy/status" && method == "GET" ->
                    200 to jsonOk("busy" to false, "stub" to true)
                path == "/deploy/log" && method == "GET" -> 200 to jsonOk("log" to "", "stub" to true)
                path == "/deploy/cancel" && method == "POST" -> 200 to jsonOk("stub" to true)
                path == "/deploy/protocols" && method == "GET" ->
                    200 to jsonOk("protocols" to JSONArray(), "stub" to true)

                path == "/platform/capabilities" && method == "GET" -> 200 to jsonOk(
                    "canShowWebView" to true, "canRunTun" to true, "canDeploy" to false,
                    "canAutoUpdate" to false, "canSendNotifications" to true,
                    "canOpenExternalUrl" to true,
                    "os" to "android", "platform" to "mobile",
                    "socks5Port" to socks5Port
                )
                path == "/platform/open-url" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/platform/notify" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/platform/open-path" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/platform/share" && method == "POST" -> 200 to jsonOk("ok" to true)

                path == "/debug/state" && method == "GET" -> 200 to jsonOk(
                    "logCount" to logs.size, "appDir" to appDir.absolutePath,
                    "vpnConnected" to vpnConnected,
                    "luaAvailable" to (luaRuntime != null),
                    "csqttLinkAvailable" to (CsqttLink.ensureAvailable(context) != null),
                    "socks5Port" to socks5Port,
                )
                path == "/debug/echo" && method == "POST" -> 200 to body
                path == "/debug/config" && method == "GET" -> 200 to jsonOk(
                    "appDir" to appDir.absolutePath,
                    "configsPath" to configsJson.absolutePath,
                    "settingsPath" to settingsFile.absolutePath,
                    "logsPath" to logsFile.absolutePath,
                    "tokenPath" to tokenFile.absolutePath,
                    "luaAvailable" to (luaRuntime != null),
                    "csqttLinkAvailable" to (CsqttLink.ensureAvailable(context) != null),
                )
                path == "/debug/reload-config" && method == "POST" -> 200 to jsonOk("ok" to true)
                path == "/debug/lua" && method == "GET" -> 200 to jsonOk(
                    "available" to (luaRuntime != null),
                    "smarttunnelRunning" to smarttunnelRunning,
                    "csqttLinkAvailable" to (CsqttLink.ensureAvailable(context) != null),
                )

                else -> 404 to jsonErr("route not found: $method $path")
            }
        } catch (e: Exception) {
            Log.e(TAG, "route error: ${e.message}", e)
            return 500 to jsonErr(e.message ?: "internal error")
        }
    }

    private fun protocolsJson(): JSONArray = JSONArray().apply {
        put(JSONObject().apply {
            put("id", "CSQTT 2.1.9")
            put("displayName", "CSQTT 2.1.9")
            put("repo", "Endlad2/csqtt-core")
            put("realtime", true)
            put("description", "Plain links; pinned release 2026.09.17.17.36")
            put("coreAsset", coreManager?.getCoreName("CSQTT 2.1.9") ?: "")
        })
        put(JSONObject().apply {
            put("id", "CSQTT 2.5.1")
            put("displayName", "CSQTT 2.5.1 ⚠")
            put("repo", "Endlad2/csqtt-core")
            put("realtime", true)
            put("description", "Latest CSQTT core; DTLS compatibility warning")
            put("coreAsset", coreManager?.getCoreName(PROTO_CSQTT) ?: "")
        })
        put(JSONObject().apply {
            put("id", PROTO_PAPERFLUX)
            put("displayName", "PaperFlux (Docs)")
            put("repo", "Endlad2/PaperFlux-core")
            put("realtime", true)
            put("description", "Пробрасывает трафик через облачные документы")
            put("coreAsset", "libopenflux.so")
        })
    }

    private fun routeCore(method: String, rest: String): Pair<Int, String> {
        val slash = rest.indexOf('/')
        val protoRaw = if (slash > 0) rest.substring(0, slash) else rest
        val proto = URLDecoder.decode(protoRaw, "UTF-8")
        val tail = if (slash > 0) rest.substring(slash + 1) else ""

        val cm = coreManager ?: return 500 to jsonErr("coreManager not ready")

        return when {
            tail == "version" && method == "GET" ->
                200 to jsonOk("version" to cm.readLatest(proto))
            tail == "latest" && method == "GET" ->
                200 to jsonOk("version" to (cm.fetchLatestVersion(proto) ?: ""))
            tail == "check" && method == "GET" -> {
                val local = cm.readLatest(proto)
                val remote = cm.fetchLatestVersion(proto) ?: ""
                200 to jsonOk(
                    "hasUpdate" to (remote.isNotEmpty() && remote != local),
                    "local" to local, "remote" to remote
                )
            }
            tail == "download" && method == "POST" -> {
                if (coreDownloading) 409 to jsonErr("already downloading")
                else {
                    coreDownloading = true
                    thread { try { cm.downloadCore(proto) } finally { coreDownloading = false } }
                    200 to jsonOk("ok" to true, "async" to true)
                }
            }
            tail == "download/sync" && method == "POST" -> {
                val ok = cm.downloadCore(proto)
                if (ok) 200 to jsonOk("ok" to true) else 500 to jsonErr("download failed")
            }
            tail == "path" && method == "GET" ->
                200 to jsonOk("path" to (cm.getCorePath(proto) ?: ""))
            tail == "" && method == "DELETE" -> {
                cm.getCorePath(proto)?.let { File(it).delete() }
                200 to jsonOk("ok" to true)
            }
            proto == "version" && tail == "" && method == "GET" ->
                200 to jsonOk("version" to cm.readLatest(PROTO_CSQTT))
            proto == "latest" && tail == "" && method == "GET" ->
                200 to jsonOk("version" to (cm.fetchLatestVersion(PROTO_CSQTT) ?: ""))
            proto == "check" && tail == "" && method == "GET" -> {
                val local = cm.readLatest(PROTO_CSQTT)
                val remote = cm.fetchLatestVersion(PROTO_CSQTT) ?: ""
                200 to jsonOk(
                    "hasUpdate" to (remote.isNotEmpty() && remote != local),
                    "local" to local, "remote" to remote
                )
            }
            proto == "path" && tail == "" && method == "GET" ->
                200 to jsonOk("path" to (cm.getCorePath(PROTO_CSQTT) ?: ""))
            proto == "download" && tail == "" && method == "POST" -> {
                if (coreDownloading) 409 to jsonErr("already downloading")
                else {
                    coreDownloading = true
                    thread { try { cm.downloadCore(PROTO_CSQTT) } finally { coreDownloading = false } }
                    200 to jsonOk("ok" to true, "async" to true)
                }
            }
            proto == "download/sync" && tail == "" && method == "POST" -> {
                val ok = cm.downloadCore(PROTO_CSQTT)
                if (ok) 200 to jsonOk("ok" to true) else 500 to jsonErr("download failed")
            }
            else -> 404 to jsonErr("core route not found: $method /core/$rest")
        }
    }

    private fun filterLogs(all: List<String>, source: String?): List<String> {
        return when (source) {
            "core" -> all.filter { it.startsWith(CORE_PREFIX) }
            "backend" -> all.filter { !it.startsWith(CORE_PREFIX) }
            else -> all
        }
    }

    private fun settingsForProto(proto: String): JSONObject {
        val upper = proto.uppercase()
        return if (
            upper == PROTO_CSQTT.uppercase() ||
            upper == PROTO_CSQTT_219.uppercase() ||
            upper == PROTO_CSQTT_251.uppercase()
        ) {
            JSONObject().apply {
                put("protocol", when {
                    upper == PROTO_CSQTT_219.uppercase() -> PROTO_CSQTT_219
                    upper == PROTO_CSQTT_251.uppercase() -> PROTO_CSQTT_251
                    else -> PROTO_CSQTT
                })
                val keys = JSONArray(listOf(
                    "peer", "vkHashes", "password", "workers", "autoApiWorkers",
                    "authMode", "obfs", "fingerprint", "clientIds",
                    "captchaMode", "vkAuthMode", "turnTransport",
                    "allowHashRedistribution", "validateVkHashes",
                    "shareVpn", "showCoreLogs"
                ))
                if (upper == PROTO_CSQTT_219.uppercase()) keys.put("deviceId")
                put("keys", keys)
                put("linkPlaceholder",
                    "csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2")
            }
        } else {
            JSONObject().apply {
                put("protocol", PROTO_PAPERFLUX)
                put("keys", JSONArray(listOf(
                    "pfTransport", "pfUrl", "pfUrls", "pfVolgaUrl",
                    "pfMode", "pfSocks5", "pfTcpRecovery",
                    "pfRelayUrl", "pfRelayToken", "pfRelayUser", "pfRelaySession",
                    "pfMaxToken", "pfMaxUid",
                    "workers", "shareVpn", "showCoreLogs"
                )))
                put("linkPlaceholder",
                    "paperflux://config?v=1&id=...&name=...&server=...&ip=...&transport=...&doc=...&token=...&volga=...")
            }
        }
    }

    private inner class EventStream(val writer: OutputStreamWriter) {
        fun send(data: String) {
            try { writer.write("data: $data\n\n"); writer.flush() } catch (_: Exception) {}
        }
    }

    private fun handleSse(socket: Socket, output: OutputStreamWriter) {
        try {
            output.write("HTTP/1.1 200 OK\r\n")
            output.write("Content-Type: text/event-stream\r\n")
            output.write("Cache-Control: no-cache\r\nConnection: keep-alive\r\n")
            output.write("Access-Control-Allow-Origin: *\r\n\r\n")
            output.flush()
            val stream = EventStream(output)
            eventSubscribers.add(stream)
            while (running && !socket.isClosed) {
                try { Thread.sleep(15_000); stream.send("""{"type":"ping"}""") }
                catch (_: Exception) { break }
            }
            eventSubscribers.remove(stream)
        } catch (e: Exception) { Log.e(TAG, "SSE: ${e.message}") }
    }

    private fun handleLogsSse(socket: Socket, output: OutputStreamWriter) {
        try {
            output.write("HTTP/1.1 200 OK\r\n")
            output.write("Content-Type: text/event-stream\r\n")
            output.write("Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n")
            output.flush()
            val stream = EventStream(output)
            eventSubscribers.add(stream)
            while (running && !socket.isClosed) {
                try { Thread.sleep(15_000) } catch (_: Exception) { break }
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
        if (logs.size > 2000) logs.removeAt(0)
        try { logsFile.appendText(line + "\n") } catch (_: Exception) {}
        emit("log", JSONObject().put("line", line).put("ts", System.currentTimeMillis() / 1000))
        luaRuntime?.onLog(line)
    }

    private fun addCoreLog(line: String) {
        Log.d(TAG, "[core] $line")
        val tagged = CORE_PREFIX + line
        logs.add(tagged)
        if (logs.size > 2000) logs.removeAt(0)
        emit("log", JSONObject().put("line", tagged).put("ts", System.currentTimeMillis() / 1000))
        luaRuntime?.onLog(tagged)
    }

    private fun ensureDefaults() {
        val deviceId = ensureDeviceId()
        if (!settingsFile.exists()) saveSettings(defaultSettings())
        else {
            val settings = try { JSONObject(settingsFile.readText()) } catch (_: Exception) { defaultSettings() }
            settings.put("deviceId", deviceId)
            saveSettings(settings)
        }
        if (!configsJson.exists()) configsJson.writeText("[]")
        if (!logsFile.exists()) logsFile.writeText("")
    }

    /** Stable UUIDv4 in app-private files; migrates a valid legacy settings ID. */
    private fun ensureDeviceId(): String {
        fun canonicalUuid(raw: String?): String? = try {
            if (raw.isNullOrBlank()) null else {
                val value = raw.trim()
                val expanded = if (value.matches(Regex("[0-9a-fA-F]{32}"))) {
                    "${value.substring(0, 8)}-${value.substring(8, 12)}-${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}"
                } else value
                java.util.UUID.fromString(expanded).let { uuid -> if (uuid.version() == 4) uuid.toString() else null }
            }
        } catch (_: Exception) { null }

        val fromFile = try {
            if (deviceIdFile.exists()) canonicalUuid(JSONObject(deviceIdFile.readText()).optString("deviceId"))
            else null
        } catch (_: Exception) { null }
        val fromSettings = try {
            if (settingsFile.exists()) canonicalUuid(JSONObject(settingsFile.readText()).optString("deviceId"))
            else null
        } catch (_: Exception) { null }
        val id = fromFile ?: fromSettings ?: java.util.UUID.randomUUID().toString()
        writeDeviceId(id)
        return id
    }

    private fun writeDeviceId(id: String) {
        deviceIdFile.parentFile?.mkdirs()
        val tmp = File(deviceIdFile.parentFile, deviceIdFile.name + ".tmp")
        tmp.writeText(JSONObject().put("deviceId", id).toString(2))
        if (deviceIdFile.exists()) deviceIdFile.delete()
        if (!tmp.renameTo(deviceIdFile)) {
            tmp.copyTo(deviceIdFile, overwrite = true)
            tmp.delete()
        }
    }

    private fun defaultSettings(): JSONObject = JSONObject().apply {
        put("peer", "")
        put("vkHashes", "")
        put("vkJsToken", "")
        put("deviceId", ensureDeviceId())
        put("workers", DEFAULT_WORKERS)
        put("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
        put("password", "")
        put("obfs", "video")
        put("fingerprint", "firefox")
        put("clientIds", "8202606,6287487")
        put("authMode", "manual")
        put("turnTransport", "udp")
        put("turnHost", "")
        put("turnPort", "")
        put("captchaMode", "auto")
        put("vkAuthMode", "vkcalls")
        put("allowHashRedistribution", false)
        put("validateVkHashes", false)
        put("pfTransport", "yandex")
        put("pfUrl", "")
        put("pfUrls", "")
        put("pfVolgaUrl", "")
        put("pfMode", "proxy")
        put("pfSocks5", "127.0.0.1:1080")
        put("pfTcpRecovery", "auto")
        put("pfSession", false)
        put("pfClientIp", "10.10.10.2")
        put("pfAuthService", "")
        put("pfIpcSocket", "")
        put("pfTunFdSock", "")
        put("pfPacketSock", "")
        put("pfExitProfiles", "")
        put("pfExitStats", "")
        put("pfExitCookies", "")
        put("pfRelayUrl", "")
        put("pfRelayToken", "")
        put("pfRelayUser", 0)
        put("pfRelaySession", "")
        put("pfMaxToken", "")
        put("pfMaxUid", "")
        put("enableSmartTunnel", false)
        put("showCoreLogs", false)
        put("shareVpn", false)
    }

    private fun loadSettings(): JSONObject = try {
        val settings = if (settingsFile.exists()) JSONObject(settingsFile.readText()) else defaultSettings()
        settings.put("deviceId", ensureDeviceId())
        settings
    } catch (_: Exception) { defaultSettings().put("deviceId", ensureDeviceId()) }

    private fun saveSettings(s: JSONObject) {
        val w = s.optInt("workers", DEFAULT_WORKERS).coerceIn(MIN_WORKERS, MAX_WORKERS)
        val aw = s.optInt("autoApiWorkers", DEFAULT_AUTO_API_WORKERS)
            .coerceIn(MIN_AUTO_API_WORKERS, MAX_AUTO_API_WORKERS)
        s.put("workers", w)
        s.put("autoApiWorkers", aw)
        s.put("deviceId", ensureDeviceId())
        try { settingsFile.writeText(s.toString()) } catch (_: Exception) {}
    }

    private fun replaceSettings(body: String): Pair<Int, String> = try {
        val s = JSONObject(body); saveSettings(s); 200 to jsonOk("ok" to true)
    } catch (e: Exception) { 400 to jsonErr(e.message ?: "bad json") }

    private fun patchSettings(body: String): Pair<Int, String> = try {
        val patch = JSONObject(body); val s = loadSettings()
        patch.keys().forEach { k -> s.put(k, patch.get(k)) }
        saveSettings(s); 200 to jsonOk("ok" to true)
    } catch (e: Exception) { 400 to jsonErr(e.message ?: "bad json") }

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
        addLog("[VK] token saved to ${tokenFile.absolutePath}")
    }

    private fun readVkState(): JSONObject {
        val has = readVkToken() != null
        return JSONObject().apply {
            put("hasToken", has)
            put("fetching", vkLoginInProgress)
            put("progress", if (has) 100 else if (vkLoginInProgress) 40 else 0)
            put("message", if (has) "VK token active"
                else if (vkLoginInProgress) vkLoginMessage else "")
        }
    }

    private fun loadConfigs(): JSONArray = try {
        if (configsJson.exists()) JSONArray(configsJson.readText()) else JSONArray()
    } catch (_: Exception) { JSONArray() }

    private fun saveConfigs(arr: JSONArray) {
        try { configsJson.writeText(arr.toString()) } catch (_: Exception) {}
    }

    private fun findConfig(id: Long): JSONObject? {
        val arr = loadConfigs()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            if (o.optLong("id") == id) return o
        }
        return null
    }

    private fun createConfig(body: String): Pair<Int, String> = try {
        val b = JSONObject(body)
        val link = b.optString("link", "")
        val protocol = b.optString("protocol", PROTO_CSQTT)
        Log.i(TAG, "[API] POST /configs link_len=${link.length} protocol=$protocol")
        val parsed = if (link.isNotEmpty()) parseLink(link, protocol) else JSONObject().apply {
            put("protocol", protocol)
            put("peer", b.optString("peer", ""))
            put("password", b.optString("password", ""))
            put("hashes", b.optString("hashes", ""))
            put("name", b.optString("name", ""))
            put("profileId", b.optString("profileId", ""))
            put("profileToken", b.optString("profileToken", ""))
            put("clientIp", b.optString("clientIp", ""))
            put("transport", b.optString("transport", ""))
            put("url", b.optString("url", ""))
            put("urls", b.optString("urls", ""))
            put("volgaUrl", b.optString("volgaUrl", ""))
            put("relayUrl", b.optString("relayUrl", ""))
            put("relayToken", b.optString("relayToken", ""))
            put("maxToken", b.optString("maxToken", ""))
            put("maxUid", b.optString("maxUid", ""))
            put("server", b.optString("server", ""))
        }
        val id = System.currentTimeMillis()
        parsed.put("id", id); parsed.put("rawLink", link)
        val arr = loadConfigs(); arr.put(parsed); saveConfigs(arr)
        Log.i(TAG, "[API] /configs INSERTED id=$id peer=${parsed.optString("peer")}")
        200 to jsonOk("id" to id)
    } catch (e: Exception) {
        Log.e(TAG, "[API] /configs insert failed: ${e.message}", e)
        400 to jsonErr(e.message ?: "bad json")
    }

    private fun updateConfig(id: Long, body: String): Pair<Int, String> = try {
        val b = JSONObject(body); val arr = loadConfigs()
        var found = false
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            if (o.optLong("id") == id) {
                b.keys().forEach { k -> o.put(k, b.get(k)) }
                o.put("id", id); found = true; break
            }
        }
        if (!found) 404 to jsonErr("not found")
        else { saveConfigs(arr); 200 to jsonOk("ok" to true) }
    } catch (e: Exception) { 400 to jsonErr(e.message ?: "bad json") }

    private fun deleteConfig(id: Long): Pair<Int, String> {
        val arr = loadConfigs(); val out = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            if (o.optLong("id") != id) out.put(o)
        }
        saveConfigs(out); return 200 to jsonOk("ok" to true)
    }

    private fun readSelectedConfig(): JSONObject? = try {
        if (selectedConfigFile.exists()) JSONObject(selectedConfigFile.readText()) else null
    } catch (_: Exception) { null }

    private fun writeSelectedConfig(c: JSONObject) {
        try { selectedConfigFile.writeText(c.toString()) } catch (_: Exception) {}
    }

    private fun clearSelectedConfig() {
        try { selectedConfigFile.delete() } catch (_: Exception) {}
    }

    // ============================================================
    //  parseLink — csqtt-link (ProcessBuilder) → Lua → нативный
    // ============================================================

    private fun parseLink(link: String, protocol: String = PROTO_CSQTT): JSONObject {
        val lower = link.trim().lowercase()
        if (lower.startsWith("paperflux://") || lower.startsWith("openflux://")) {
            return parsePaperFlux(link)
        }
        return parseCsqtt(link, protocol).apply {
            if (protocol.equals("CSQTT 2.5.1", ignoreCase = true)) {
                put("protocol", "CSQTT 2.5.1")
            }
        }
    }

    private fun parseCsqtt(link: String, protocol: String = PROTO_CSQTT): JSONObject {
        if (protocol.equals("CSQTT 2.1.9", ignoreCase = true)) {
            Log.i(TAG, "[PARSE][CSQTT 2.1.9] parsing plain link; csqtt-link decryption skipped")
            return parseCsqttNative(link).apply {
                put("protocol", "CSQTT 2.1.9")
                put("rawLink", link)
            }
        }
        Log.i(TAG, "[PARSE][CSQTT] start, link_len=${link.length}")

        // ---- 1. csqtt-link (libcsqtt-link.so через ProcessBuilder) ----
        Log.i(TAG, "[PARSE][CSQTT] trying csqtt-link (ProcessBuilder)...")
        val json = CsqttLink.parse(context, link)
        if (json != null) {
            try {
                val host = json.optString("host", "")
                val port = json.optInt("port", 0)
                if (host.isNotEmpty() && port > 0) {
                    val peer = "$host:$port"
                    val hashesArr = json.optJSONArray("hashes")
                    val hashesStr = StringBuilder()
                    if (hashesArr != null) {
                        for (i in 0 until hashesArr.length()) {
                            if (i > 0) hashesStr.append(',')
                            hashesStr.append(hashesArr.getString(i))
                        }
                    }
                    Log.i(TAG, "[PARSE][CSQTT] csqtt-link OK: host=$host port=$port hashes=${hashesStr.length}")
                    return JSONObject().apply {
                        put("protocol", "CSQTT")
                        put("peer", peer)
                        put("password", json.optString("password", ""))
                        put("hashes", hashesStr.toString())
                        put("name", peer)
                        put("rawLink", link)
                    }
                } else {
                    Log.w(TAG, "[PARSE][CSQTT] csqtt-link returned empty host/port")
                }
            } catch (e: Exception) {
                Log.w(TAG, "[PARSE][CSQTT] csqtt-link json parse failed: ${e.message}")
            }
        } else {
            Log.w(TAG, "[PARSE][CSQTT] csqtt-link returned null (not available or failed)")
        }

        // ---- 2. Lua ----
        val lua = luaRuntime
        if (lua != null) {
            Log.i(TAG, "[PARSE][CSQTT] trying Lua (csqtt_decode.lua)...")
            val decoded = lua.decodeCsqttLink(link)
            if (decoded != null) {
                Log.i(TAG, "[PARSE][CSQTT] Lua OK: peer=${decoded.peer}")
                return JSONObject().apply {
                    put("protocol", "CSQTT")
                    put("peer", decoded.peer)
                    put("password", decoded.password)
                    put("hashes", decoded.hashes)
                    put("name", if (decoded.name.isEmpty()) decoded.peer else decoded.name)
                    put("rawLink", link)
                }
            } else {
                Log.w(TAG, "[PARSE][CSQTT] Lua returned null")
            }
        } else {
            Log.w(TAG, "[PARSE][CSQTT] luaRuntime not initialized, skip")
        }

        // ---- 3. Нативный fallback ----
        Log.i(TAG, "[PARSE][CSQTT] trying native fallback...")
        return parseCsqttNative(link)
    }

    private fun parseCsqttNative(link: String): JSONObject {
        val out = JSONObject().apply {
            put("protocol", PROTO_CSQTT); put("peer", ""); put("password", "")
            put("hashes", ""); put("name", "")
        }
        if (!link.startsWith("csqtt://", ignoreCase = true)) {
            out.put("peer", link); return out
        }
        val rest = link.removePrefix("csqtt://")
        if (rest.startsWith("connect?")) {
            val query = rest.removePrefix("connect?")
            var host = ""; var port = ""; var password = ""; var hashes = ""
            query.split("&").forEach { kv ->
                val idx = kv.indexOf('=')
                if (idx > 0) {
                    val k = kv.substring(0, idx); val v = kv.substring(idx + 1)
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

    private fun parsePaperFlux(link: String): JSONObject {
        val out = JSONObject().apply {
            put("protocol", PROTO_PAPERFLUX)
            put("profileId", ""); put("profileToken", "")
            put("clientIp", ""); put("transport", "")
            put("url", ""); put("urls", ""); put("volgaUrl", "")
            put("relayUrl", ""); put("relayToken", "")
            put("maxToken", ""); put("maxUid", "")
            put("server", ""); put("peer", ""); put("name", "")
        }
        val idx = link.indexOf("://")
        if (idx < 0) return out
        var rest = link.substring(idx + 3)
        if (rest.startsWith("config?")) rest = rest.removePrefix("config?")
        else if (rest.startsWith("config&")) rest = rest.removePrefix("config&")
        else if (rest.startsWith("config")) rest = rest.removePrefix("config")

        var name = ""; var server = ""
        rest.split("&").forEach { kv ->
            val eq = kv.indexOf('=')
            if (eq <= 0) return@forEach
            val k = kv.substring(0, eq)
            val v = urlDecode(kv.substring(eq + 1))
            when (k) {
                "id" -> out.put("profileId", v)
                "name" -> name = v
                "server" -> server = v
                "ip" -> out.put("clientIp", v)
                "transport" -> out.put("transport", v)
                "doc", "url" -> out.put("url", v)
                "urls" -> out.put("urls", v)
                "token" -> out.put("profileToken", v)
                "volga", "volga_url", "volga-url" -> out.put("volgaUrl", v)
                "relay_url", "relayUrl" -> out.put("relayUrl", v)
                "relay_token", "relayToken" -> out.put("relayToken", v)
                "maxToken" -> out.put("maxToken", v)
                "maxUid" -> out.put("maxUid", v)
            }
        }
        val display = if (name.isEmpty()) "PaperFlux" else name
        out.put("name", display)
        out.put("server", server)
        out.put("peer", server)
        return out
    }

    private fun urlDecode(s: String): String {
        return try {
            URLDecoder.decode(s, "UTF-8")
        } catch (_: Exception) { s }
    }

    private fun vpnConnect(body: String): Pair<Int, String> {
        val settings = loadSettings()
        val sel = readSelectedConfig()
        val protocol = sel?.optString("protocol", PROTO_CSQTT) ?: PROTO_CSQTT
        val cm = coreManager ?: return 500 to jsonErr("coreManager not ready")

        if (cm.getCorePath(protocol) == null) {
            addLog("[VPN] $protocol core not installed, downloading...")
            if (!cm.downloadCore(protocol)) return 500 to jsonErr("core download failed")
        }

        if (protocol.equals(PROTO_PAPERFLUX, ignoreCase = true)) {
            val peer = sel?.optString("server", "") ?: ""
            if (peer.isEmpty()) return 400 to jsonErr("no server in PaperFlux config")

            val args = buildPaperFluxArgs(sel, settings)
            addLog("[VPN] PaperFlux core args: ${args.joinToString(" ")}")

            val started = cm.startCore(
                protocol = protocol,
                args = args,
                onLog = { line -> addCoreLog(line) }
            )
            if (!started) return 500 to jsonErr("paperflux core start failed")

            mainHandler.post {
                val act = activity
                if (act == null) { startVpnService(); return@post }
                val intent = VpnService.prepare(act)
                if (intent != null) act.startActivityForResult(intent, REQ_VPN)
                else startVpnService()
            }
            luaRuntime?.onConnect()
            return 200 to jsonOk("ok" to true, "status" to "connecting")
        }

        val peer = sel?.optString("peer", "") ?: settings.optString("peer", "")
        if (peer.isNullOrEmpty()) return 400 to jsonErr("no config selected")

        val password = sel?.optString("password", "") ?: settings.optString("password", "")

        // Fallback: если в конфиге хешей нет — берём из settings.vkHashes.
        val cfgHashes = sel?.optString("hashes", "") ?: ""
        val hashes = if (cfgHashes.isNotEmpty()) cfgHashes
                     else settings.optString("vkHashes", "")

        val started = cm.startCore(
            protocol = protocol,
            peer = peer,
            password = password,
            hashes = hashes,
            onLog = { line -> addCoreLog(line) }
        )
        if (!started) return 500 to jsonErr("csqtt core start failed")

        if (settings.optBoolean("shareVpn", false)) startSocks5()

        mainHandler.post {
            val act = activity
            if (act == null) { startVpnService(); return@post }
            val intent = VpnService.prepare(act)
            if (intent != null) act.startActivityForResult(intent, REQ_VPN)
            else startVpnService()
        }
        luaRuntime?.onConnect()
        return 200 to jsonOk("ok" to true, "status" to "connecting")
    }

    private fun buildPaperFluxArgs(
        cfg: JSONObject?,
        settings: JSONObject,
    ): List<String> {
        val args = mutableListOf<String>()
        args += "--client"

        fun fromCfgOrSettings(cfgKey: String, settingsKey: String, fallback: String = ""): String {
            val fromCfg = cfg?.optString(cfgKey, "") ?: ""
            if (fromCfg.isNotEmpty()) return fromCfg
            val fromSettings = settings.optString(settingsKey, "")
            return if (fromSettings.isNotEmpty()) fromSettings else fallback
        }

        val profileId = fromCfgOrSettings("profileId", "pfProfileId")
        if (profileId.isNotEmpty()) { args += "--profile-id"; args += profileId }

        val profileToken = fromCfgOrSettings("profileToken", "pfProfileToken")
        if (profileToken.isNotEmpty()) { args += "--profile-token"; args += profileToken }

        val clientIp = fromCfgOrSettings("clientIp", "pfClientIp", "10.10.10.2")
        args += "--client-ip"; args += clientIp

        val transport = fromCfgOrSettings("transport", "pfTransport", "yandex")
        args += "--transport"; args += transport

        if (settings.optBoolean("pfSession", false)) args += "--session"
        val tcpRecovery = settings.optString("pfTcpRecovery", "")
        if (tcpRecovery.isNotEmpty()) { args += "--tcp-recovery"; args += tcpRecovery }

        val url = fromCfgOrSettings("url", "pfUrl")
        if (url.isNotEmpty()) { args += "--url"; args += url }
        val urls = fromCfgOrSettings("urls", "pfUrls")
        if (urls.isNotEmpty()) { args += "--urls"; args += urls }
        val volga = fromCfgOrSettings("volgaUrl", "pfVolgaUrl")
        if (volga.isNotEmpty()) { args += "--volga-url"; args += volga }

        args += "--mode"; args += "proxy"
        args += "--socks5"; args += "127.0.0.1:1080"

        val relayUrl = fromCfgOrSettings("relayUrl", "pfRelayUrl")
        if (relayUrl.isNotEmpty()) { args += "--relay-url"; args += relayUrl }
        val relayToken = fromCfgOrSettings("relayToken", "pfRelayToken")
        if (relayToken.isNotEmpty()) { args += "--relay-token"; args += relayToken }
        val relayUser = settings.optInt("pfRelayUser", 0)
        if (relayUser > 0) { args += "--relay-user"; args += relayUser.toString() }
        val relaySession = settings.optString("pfRelaySession", "")
        if (relaySession.isNotEmpty()) { args += "--relay-session"; args += relaySession }

        val maxToken = fromCfgOrSettings("maxToken", "pfMaxToken")
        if (maxToken.isNotEmpty()) { args += "--maxToken"; args += maxToken }
        val maxUid = fromCfgOrSettings("maxUid", "pfMaxUid")
        if (maxUid.isNotEmpty()) { args += "--maxUid"; args += maxUid }

        return args
    }

    fun onVpnPermissionGranted() {
        addLog("[VPN] permission granted, starting service")
        startVpnService()
    }

    fun onVpnPermissionDenied() {
        addLog("[VPN] permission denied")
        vpnConnected = false
        emit("status", JSONObject().put("connected", false))
    }

    private fun startVpnService() {
        val i = Intent(context, LaLuneVpnService::class.java).apply { action = "START" }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(i)
        } else {
            context.startService(i)
        }
    }

    private fun vpnDisconnect(): Pair<Int, String> {
        val i = Intent(context, LaLuneVpnService::class.java).apply { action = "STOP" }
        try { context.startService(i) } catch (_: Exception) {}
        coreManager?.stopCore()
        stopSocks5()
        vpnConnected = false
        emit("status", JSONObject().put("connected", false))
        addLog("[VPN] disconnect")
        luaRuntime?.onDisconnect()
        return 200 to jsonOk("ok" to true)
    }

    /** Запускает SOCKS5 на свободном порту. */
    private fun startSocks5() {
        if (socks5Server != null) { addLog("[PROXY] already running"); return }
        try {
            val server = Socks5Server(0) { line -> addLog(line) }
            val port = server.start()
            socks5Server = server
            socks5Port = port
            addLog("[PROXY] SOCKS5 listening on 0.0.0.0:$port")
        } catch (e: Exception) {
            addLog("[PROXY] failed to start: ${e.message}")
        }
    }

    private fun stopSocks5() {
        try { socks5Server?.stop() } catch (_: Exception) {}
        socks5Server = null
        socks5Port = 0
    }

    private fun vkLogin(): Pair<Int, String> {
        if (vkLoginInProgress) return 200 to jsonOk(
            "ok" to true, "needsUi" to false, "message" to "already in progress"
        )
        val act = activity ?: return 500 to jsonErr("activity not attached")
        vkLoginInProgress = true
        vkLoginMessage = "Открываю окно авторизации..."
        addLog("[VK] opening WebView...")

        mainHandler.post {
            val fetcher = VkWebViewFetcher(
                activity = act,
                onSuccess = { token ->
                    vkLoginInProgress = false
                    vkLoginMessage = ""
                    saveVkToken(token)
                    addLog("[VK] token received successfully")
                    emit("progress", JSONObject().apply {
                        put("kind", "vk_token"); put("percent", 100)
                    })
                },
                onError = { message ->
                    vkLoginInProgress = false
                    vkLoginMessage = message
                    addLog("[VK] error: $message")
                    emit("error", JSONObject().put("message", "VK: $message"))
                },
            )
            currentVkFetcher = fetcher
            fetcher.start()
        }
        return 200 to jsonOk("ok" to true, "needsUi" to false)
    }

    private fun vkCallsStart(body: String): Pair<Int, String> {
        val token = readVkToken() ?: return 400 to jsonErr("no VK token")
        return try {
            val b = JSONObject(body)
            val s = loadSettings()
            val workers = b.optInt("workers", s.optInt("workers", DEFAULT_WORKERS))
            val aw = b.optInt("autoApiWorkers",
                s.optInt("autoApiWorkers", DEFAULT_AUTO_API_WORKERS))
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
            val conn = URL(VK_API_BASE + "calls.start").openConnection() as HttpURLConnection
            conn.requestMethod = "POST"; conn.doOutput = true
            conn.connectTimeout = 8000; conn.readTimeout = 8000
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            conn.setRequestProperty("User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
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
        } catch (_: Exception) { Triple("", "", -1) }
    }

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
                return URLDecoder.decode(kv.substring(idx + 1), "UTF-8")
            }
        }
        return null
    }
}
