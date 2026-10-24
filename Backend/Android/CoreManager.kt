// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро: CSQTT + PaperFlux. deviceId удалён из аргументов CSQTT.

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

        const val PROTO_CSQTT = "CSQTT"
        const val PROTO_CSQTT_219 = "CSQTT 2.1.9"
        const val PROTO_CSQTT_251 = "CSQTT 2.5.1"
        const val PROTO_PAPERFLUX = "PaperFlux"
        const val CSQTT_219_RELEASE = "2026.09.17.17.36"

        const val LATEST_CSQTT_URL =
            "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
        const val LATEST_PAPERFLUX_URL =
            "https://raw.githubusercontent.com/Endlad2/PaperFlux-core/refs/heads/main/LATEST"

        const val CSQTT_URL_TEMPLATE =
            "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
        const val PAPERFLUX_URL_TEMPLATE =
            "https://github.com/Endlad2/PaperFlux-core/releases/latest/download/%s"

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
    private val latestCsqtt = File(appDir, "LATEST.Csqtt")
    private val latestCsqtt219 = File(appDir, "LATEST.CSQTT-2.1.9")
    private val latestPaper = File(appDir, "LATEST.PaperFlux")

    private var coreProcess: Process? = null

    @Volatile
    var isRunning: Boolean = false
        private set

    fun getCoreName(protocol: String): String? {
        val abi = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
        return when (protocol.uppercase()) {
            PROTO_CSQTT_219.uppercase() -> when {
                abi.contains("arm64") -> "libclient-android-arm64-v8a-219.so"
                abi.contains("armeabi-v7a") -> "libclient-android-armeabi-v7a-219.so"
                abi.contains("arm") -> "libclient-android-armeabi-v7a-219.so"
                abi.contains("x86_64") -> "libclient-android-x86_64-219.so"
                else -> null
            }
            PROTO_CSQTT.uppercase(), PROTO_CSQTT_251.uppercase() -> when {
                abi.contains("arm64") -> "libclient-android-arm64-v8a.so"
                abi.contains("arm") -> "libclient-android-armeabi-v7a.so"
                abi.contains("x86_64") -> "libclient-android-x86_64.so"
                else -> null
            }
            PROTO_PAPERFLUX.uppercase() -> "libopenflux.so"
            else -> null
        }
    }

    private fun getRemoteAssetName(protocol: String): String? {
        return when (protocol.uppercase()) {
            PROTO_CSQTT.uppercase(), PROTO_CSQTT_219.uppercase(), PROTO_CSQTT_251.uppercase() -> getCoreName(PROTO_CSQTT)
            PROTO_PAPERFLUX.uppercase() -> {
                val abi = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
                when {
                    abi.contains("arm64") -> "arm64-v8a/libopenflux.so"
                    abi.contains("armeabi-v7a") -> "armeabi-v7a/libopenflux.so"
                    abi.contains("x86_64") -> "x86_64/libopenflux.so"
                    abi.contains("x86") -> "x86/libopenflux.so"
                    else -> null
                }
            }
            else -> null
        }
    }

    fun getCorePath(protocol: String): String? {
        val name = getCoreName(protocol) ?: return null
        val native = File(context.applicationInfo.nativeLibraryDir, name)
        if (native.exists()) return native.absolutePath
        val cached = File(coreDir, name)
        if (cached.exists() && cached.length() > 1024) return cached.absolutePath
        return null
    }

    fun readLatest(protocol: String = PROTO_CSQTT): String = try {
        val f = latestFileFor(protocol)
        if (f.exists()) f.readText().trim() else ""
    } catch (_: Exception) { "" }

    private fun latestFileFor(protocol: String): File = when {
        protocol.equals(PROTO_PAPERFLUX, ignoreCase = true) -> latestPaper
        protocol.equals(PROTO_CSQTT_219, ignoreCase = true) -> latestCsqtt219
        else -> latestCsqtt
    }

    fun fetchLatestVersion(protocol: String = PROTO_CSQTT): String? {
        if (protocol.equals(PROTO_CSQTT_219, ignoreCase = true)) return CSQTT_219_RELEASE
        val baseUrl = if (protocol.equals(PROTO_PAPERFLUX, ignoreCase = true))
            LATEST_PAPERFLUX_URL else LATEST_CSQTT_URL
        for (level in 1..3) {
            try {
                val url = when (level) {
                    1 -> baseUrl
                    else -> PROXY_URL + URLEncoder.encode(baseUrl, "UTF-8")
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

    fun downloadCore(protocol: String = PROTO_CSQTT): Boolean {
        return when {
            protocol.equals(PROTO_PAPERFLUX, ignoreCase = true) -> downloadPaperFlux()
            protocol.equals(PROTO_CSQTT_219, ignoreCase = true) -> downloadCsqtt219()
            else -> downloadCsqtt()
        }
    }

    private fun downloadCsqtt(): Boolean {
        val name = getRemoteAssetName(PROTO_CSQTT) ?: return false
        val version = fetchLatestVersion(PROTO_CSQTT) ?: return false
        val url = String.format(CSQTT_URL_TEMPLATE, version, name)
        Log.i(TAG, "[CORE] downloading CSQTT 2.5.1/latest $url")

        return downloadFrom(url, File(coreDir, getCoreName(PROTO_CSQTT)!!)).also { ok ->
            if (ok) try { latestCsqtt.writeText(version) } catch (_: Exception) {}
        }
    }

    private fun downloadCsqtt219(): Boolean {
        val remoteName = getRemoteAssetName(PROTO_CSQTT) ?: return false
        val localName = getCoreName(PROTO_CSQTT_219) ?: return false
        val url = String.format(CSQTT_URL_TEMPLATE, CSQTT_219_RELEASE, remoteName)
        Log.i(TAG, "[CORE] downloading CSQTT 2.1.9 pinned release $url")
        return downloadFrom(url, File(coreDir, localName)).also { ok ->
            if (ok) try { latestCsqtt219.writeText(CSQTT_219_RELEASE) } catch (_: Exception) {}
        }
    }

    private fun downloadPaperFlux(): Boolean {
        val abi = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return false
        val abiDir = when {
            abi.contains("arm64") -> "arm64-v8a"
            abi.contains("armeabi-v7a") -> "armeabi-v7a"
            abi.contains("x86_64") -> "x86_64"
            abi.contains("x86") -> "x86"
            else -> return false
        }
        val zipUrl = "https://github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-android.zip"
        Log.i(TAG, "[CORE] downloading PaperFlux $zipUrl")

        for (level in 1..3) {
            try {
                val useUrl = when (level) {
                    1 -> zipUrl
                    else -> PROXY_URL + URLEncoder.encode(zipUrl, "UTF-8")
                }
                val conn = URL(useUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 30_000
                conn.readTimeout = 120_000
                conn.setRequestProperty("User-Agent", if (level == 3) UA_CURL else UA_BROWSER)
                if (conn.responseCode == 200) {
                    val tmpZip = File(coreDir, "paperflux-android.zip.tmp")
                    conn.inputStream.use { input ->
                        FileOutputStream(tmpZip).use { output -> input.copyTo(output) }
                    }
                    if (tmpZip.length() < 1024) { tmpZip.delete(); continue }

                    val dest = File(coreDir, "libopenflux.so")
                    if (extractFileFromZip(tmpZip, "$abiDir/libopenflux.so", dest)) {
                        dest.setExecutable(true, false)
                        try { latestPaper.writeText("latest") } catch (_: Exception) {}
                        tmpZip.delete()
                        Log.i(TAG, "[CORE] PaperFlux extracted OK (${dest.length()} bytes)")
                        return true
                    }
                    tmpZip.delete()
                }
            } catch (e: Exception) {
                Log.w(TAG, "[DOWNLOAD][LEVEL $level] ${e.message}")
            }
        }
        return false
    }

    private fun extractFileFromZip(zip: File, entryName: String, dest: File): Boolean {
        return try {
            java.util.zip.ZipFile(zip).use { zf ->
                val entry = zf.entries().asSequence()
                    .firstOrNull { it.name.replace('\\', '/').endsWith(entryName) }
                    ?: return false
                zf.getInputStream(entry).use { input ->
                    FileOutputStream(dest).use { output -> input.copyTo(output) }
                }
            }
            dest.length() > 1024
        } catch (e: Exception) {
            Log.w(TAG, "extractFileFromZip: ${e.message}")
            false
        }
    }

    private fun downloadFrom(baseUrl: String, dest: File): Boolean {
        for (level in 1..3) {
            try {
                val useUrl = when (level) {
                    1 -> baseUrl
                    else -> PROXY_URL + URLEncoder.encode(baseUrl, "UTF-8")
                }
                val conn = URL(useUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 30_000
                conn.readTimeout = 60_000
                conn.setRequestProperty("User-Agent", if (level == 3) UA_CURL else UA_BROWSER)
                if (conn.responseCode == 200) {
                    val tmp = File(dest.parentFile, dest.name + ".tmp")
                    conn.inputStream.use { input ->
                        FileOutputStream(tmp).use { output -> input.copyTo(output) }
                    }
                    if (tmp.length() > 1024) {
                        if (dest.exists()) dest.delete()
                        tmp.renameTo(dest)
                        dest.setExecutable(true, false)
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
        protocol: String = PROTO_CSQTT,
        peer: String = "",
        password: String = "",
        hashes: String = "",
        args: List<String>? = null,
        onLog: (String) -> Unit,
    ): Boolean {
        val corePath = getCorePath(protocol) ?: run {
            Log.e(TAG, "[CORE] $protocol not installed")
            return false
        }

        val finalArgs = if (args != null) {
            listOf(corePath) + args
        } else {
            buildCsqttArgs(corePath, protocol, peer, password, hashes)
        }

        return try {
            logsFile.writeText("")
            onLog("[CORE] starting: ${finalArgs.joinToString(" ")}")

            val pb = ProcessBuilder(finalArgs)
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
                        try { logsFile.appendText(l + "\n") } catch (_: Exception) {}
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

    /** buildCsqttArgs: deviceId УБРАН — новое ядро его не принимает. */
    private fun buildCsqttArgs(
        corePath: String,
        protocol: String,
        peer: String,
        password: String,
        hashes: String,
    ): List<String> {
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
        val deviceId = settings.optString("deviceId", "").trim()

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
            // deviceId УБРАН.
        )
        if (clean.isNotEmpty()) {
            args.add("-vk")
            args.add(clean.joinToString(","))
        }
        if (protocol.equals(PROTO_CSQTT_219, ignoreCase = true) && deviceId.isNotEmpty()) {
            args.add("-device-id")
            args.add(deviceId)
        }
        return args
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
