// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро CSQTT: скачивание, запуск, парсинг логов.
//
// package = com.lalune.lalune — тот же, что у MainActivity и Backend.

package com.lalune.lalune

import android.content.Context
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.regex.Pattern

class CoreManager(private val context: Context) {

    companion object {
        private const val TAG = "LaLune-Core"

        const val LATEST_URL =
            "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
        const val CORE_URL_TEMPLATE =
            "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
        const val PROXY_URL = "http://31.77.148.203:8855/?url="
        const val UA_BROWSER =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        const val UA_CURL = "curl/7.68.0"

        private val TUNCONF_RE = Pattern.compile("TUNCONF:([\\d.]+):([\\d.,]+)")
        private val TUNCONF_ALT_RE = Pattern.compile(
            "Tunnel IP:\\s*([\\d.]+)(?:/\\d+)?\\s*\\|\\s*DNS:\\s*([\\d.,]+)"
        )
        private val STATS_RE = Pattern.compile(
            "\\[СТАТИСТИКА\\]\\s*Активных:\\s*(\\d+)\\s*\\|\\s*Трафи[кф]+:\\s*([\\d.]+)"
        )
    }

    private val appDir = File(context.filesDir, "la-lune").apply { mkdirs() }
    private val coreDir = File(appDir, "core").apply { mkdirs() }
    private val logsFile = File(appDir, "logs.log")
    private val latestFile = File(appDir, "LATEST")

    private var coreProcess: Process? = null

    @Volatile
    var isRunning: Boolean = false
        private set

    fun getCoreName(): String? {
        val arch = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
        return when {
            arch.contains("arm64") -> "libclient-android-arm64-v8a.so"
            arch.contains("arm") -> "libclient-android-armeabi-v7a.so"
            arch.contains("x86_64") -> "libclient-android-x86_64.so"
            else -> null
        }
    }

    fun getCorePath(): String? {
        val name = getCoreName() ?: return null
        val native = File(context.applicationInfo.nativeLibraryDir, name)
        if (native.exists()) return native.absolutePath
        val cached = File(coreDir, name)
        if (cached.exists() && cached.length() > 1024) return cached.absolutePath
        return null
    }

    fun readLatest(): String = try {
        if (latestFile.exists()) latestFile.readText().trim() else ""
    } catch (_: Exception) { "" }

    fun fetchLatestVersion(): String? {
        for (level in 1..3) {
            try {
                val url = when (level) {
                    1 -> LATEST_URL
                    else -> PROXY_URL + URLEncoder.encode(LATEST_URL, "UTF-8")
                }
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 30_000
                conn.readTimeout = 30_000
                conn.setRequestProperty("User-Agent", if (level == 3) UA_CURL else UA_BROWSER)
                if (conn.responseCode == 200) {
                    val text = BufferedReader(InputStreamReader(conn.inputStream)).readText().trim()
                    if (text.isNotEmpty() &&
                        !text.contains("Server error") &&
                        !text.contains("No connection adapters") &&
                        !text.contains("curl error")
                    ) {
                        return text
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "[NET][LEVEL $level] ${e.message}")
            }
        }
        return null
    }

    fun downloadCore(): Boolean {
        val name = getCoreName() ?: return false
        val version = fetchLatestVersion() ?: return false
        val url = String.format(CORE_URL_TEMPLATE, version, name)
        Log.i(TAG, "[CORE] downloading $url")

        for (level in 1..3) {
            try {
                val useUrl = when (level) {
                    1 -> url
                    else -> PROXY_URL + URLEncoder.encode(url, "UTF-8")
                }
                val conn = URL(useUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 30_000
                conn.readTimeout = 60_000
                conn.setRequestProperty("User-Agent", if (level == 3) UA_CURL else UA_BROWSER)
                if (conn.responseCode == 200) {
                    val tmp = File(coreDir, "$name.tmp")
                    conn.inputStream.use { input ->
                        FileOutputStream(tmp).use { output -> input.copyTo(output) }
                    }
                    if (tmp.length() > 1024) {
                        val dest = File(coreDir, name)
                        if (dest.exists()) dest.delete()
                        tmp.renameTo(dest)
                        dest.setExecutable(true, false)
                        latestFile.writeText(version)
                        Log.i(TAG, "[CORE] downloaded OK (${dest.length()} bytes)")
                        return true
                    }
                    tmp.delete()
                }
            } catch (e: Exception) {
                Log.w(TAG, "[DOWNLOAD][LEVEL $level] ${e.message}")
            }
        }
        return false
    }

    fun startCore(
        peer: String,
        password: String,
        hashes: String,
        onLog: (String) -> Unit,
    ): Boolean {
        val corePath = getCorePath() ?: run {
            Log.e(TAG, "[CORE] not installed")
            return false
        }

        val settingsFile = File(appDir, "settings.json")
        val settings = if (settingsFile.exists()) {
            try { org.json.JSONObject(settingsFile.readText()) }
            catch (_: Exception) { org.json.JSONObject() }
        } else org.json.JSONObject()

        var workers = settings.optInt("workers", 9)
        if (workers < 1) workers = 9
        if (workers > 127) workers = 127

        val obfs = settings.optString("obfs", "video")
        val fingerprint = settings.optString("fingerprint", "firefox")
        val clientIds = settings.optString("clientIds", "8202606,6287487")
        val vkAuthMode = settings.optString("vkAuthMode", "vkcalls")
        val captchaMode = settings.optString("captchaMode", "auto")
        val turnTransport = settings.optString("turnTransport", "udp")

        var deviceId = settings.optString("deviceId", "")
        if (deviceId.isBlank()) {
            deviceId = java.util.UUID.randomUUID().toString().replace("-", "")
            settings.put("deviceId", deviceId)
            try { settingsFile.writeText(settings.toString()) } catch (_: Exception) {}
        }

        val normalized = hashes.replace(' ', ',').replace('\t', ',')
            .replace('\n', ',').replace('\r', ',')
        val clean = normalized.split(',').map { it.trim() }
            .filter { it.isNotEmpty() }
            .take(6)

        val args = mutableListOf(
            corePath,
            "-peer", peer,
            "-password", password,
            "-n", workers.toString(),
            "-listen", "127.0.0.1:52230",
            "-obfs", obfs,
            "-fingerprint", fingerprint,
            "-client-ids", clientIds,
            "-vk-auth-mode", vkAuthMode,
            "-captcha-mode", captchaMode,
            "-turn-transport", turnTransport,
            "-device-id", deviceId,
        )
        if (clean.isNotEmpty()) {
            args.add("-vk")
            args.add(clean.joinToString(","))
        }

        return try {
            logsFile.writeText("")
            onLog("[CORE] starting: ${args.joinToString(" ")}")

            val pb = ProcessBuilder(args)
            pb.redirectErrorStream(true)
            pb.directory(coreDir)

            val proc = pb.start()
            coreProcess = proc
            isRunning = true

            Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(proc.inputStream))
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        val l = line ?: continue
                        try {
                            logsFile.appendText(l + "\n")
                        } catch (_: Exception) {}
                        onLog(l)
                    }
                } catch (_: Exception) {}
                isRunning = false
                onLog("[CORE] process exited")
            }.apply { isDaemon = true }.start()

            true
        } catch (e: Exception) {
            Log.e(TAG, "[CORE] start failed: ${e.message}", e)
            onLog("[CORE] start failed: ${e.message}")
            false
        }
    }

    fun stopCore() {
        isRunning = false
        try {
            coreProcess?.destroy()
            coreProcess = null
        } catch (e: Exception) {
            Log.w(TAG, "[CORE] stop: ${e.message}")
        }
    }

    fun parseTunconf(line: String): Pair<String, String>? {
        TUNCONF_RE.matcher(line).let { m ->
            if (m.find()) return m.group(1) to m.group(2)
        }
        TUNCONF_ALT_RE.matcher(line).let { m ->
            if (m.find()) return m.group(1) to m.group(2)
        }
        return null
    }

    fun parseStats(line: String): Pair<Int, Double>? {
        STATS_RE.matcher(line).let { m ->
            if (m.find()) {
                val active = m.group(1).toIntOrNull() ?: 0
                val traffic = m.group(2).toDoubleOrNull() ?: 0.0
                return active to traffic
            }
        }
        return null
    }
}
