package com.lalune.app

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlinx.coroutines.*
import java.io.BufferedReader
import java.io.InputStreamReader

class CoreManager(private val context: Context) {
    private val appDir: File by lazy { File(context.filesDir, "la-lune") }
    private val coreDir: File by lazy { File(appDir, "core") }

    // Логи ядра — единый файл, который читает и UI, и LaLuneVpnService.
    // (Публичное поле val автоматически даёт геттер getLogsFile() — ручной не нужен.)
    val logsFile: File by lazy { File(appDir, "logs.log") }

    private val latestFile: File by lazy { File(appDir, "LATEST") }
    private var coreProcess: Process? = null
    private var isRunning = false

    private val LATEST_URL = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
    private val CORE_URL_TEMPLATE = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
    private val PROXY_URL = "http://31.77.148.203:8855/?url="
    private val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

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
        val coreName = getCoreName() ?: return null
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val coreFile = File(nativeDir, coreName)
        return if (coreFile.exists()) coreFile.absolutePath else null
    }

    suspend fun checkCore(): Boolean = withContext(Dispatchers.IO) {
        val corePath = getCorePath()
        if (corePath != null) {
            writeLog("[CORE] Ядро найдено: $corePath")
            return@withContext true
        }
        writeLog("[CORE] Ядро не найдено, скачиваю...")
        return@withContext downloadCore()
    }

    private suspend fun downloadCore(): Boolean = withContext(Dispatchers.IO) {
        val coreName = getCoreName() ?: return@withContext false
        coreDir.mkdirs()

        val version = fetchLatestVersion()
        if (version == null) {
            writeLog("[ERROR] Не удалось получить LATEST")
            return@withContext false
        }

        val url = String.format(CORE_URL_TEMPLATE, version, coreName)
        writeLog("[CORE] Скачивание: $url")

        val destFile = File(coreDir, coreName)
        if (!downloadFile(url, destFile)) {
            writeLog("[ERROR] Не удалось скачать ядро")
            return@withContext false
        }

        latestFile.writeText(version)
        destFile.setExecutable(true, false)
        writeLog("[CORE] Ядро скачано: ${destFile.absolutePath}")
        return@withContext true
    }

    private suspend fun fetchLatestVersion(): String? = withContext(Dispatchers.IO) {
        try {
            val conn = URL(LATEST_URL).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode == 200) {
                return@withContext BufferedReader(InputStreamReader(conn.inputStream)).readText().trim()
            }
        } catch (e: Exception) {
            writeLog("[NET] Уровень 1: ${e.message}")
        }

        try {
            val proxyUrl = PROXY_URL + URLEncoder.encode(LATEST_URL, "UTF-8")
            val conn = URL(proxyUrl).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode == 200) {
                return@withContext BufferedReader(InputStreamReader(conn.inputStream)).readText().trim()
            }
        } catch (e: Exception) {
            writeLog("[NET] Уровень 2: ${e.message}")
        }

        try {
            val proxyUrl = PROXY_URL + URLEncoder.encode(LATEST_URL, "UTF-8")
            val conn = URL(proxyUrl).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", "curl/7.68.0")
            if (conn.responseCode == 200) {
                return@withContext BufferedReader(InputStreamReader(conn.inputStream)).readText().trim()
            }
        } catch (e: Exception) {
            writeLog("[NET] Уровень 3: ${e.message}")
        }

        return@withContext null
    }

    private suspend fun downloadFile(url: String, dest: File): Boolean = withContext(Dispatchers.IO) {
        dest.parentFile?.mkdirs()

        try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 60000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    FileOutputStream(dest).use { output -> input.copyTo(output) }
                }
                if (dest.length() > 1024) {
                    writeLog("[DOWNLOAD] Уровень 1 OK (${dest.length()} байт)")
                    return@withContext true
                }
            }
        } catch (e: Exception) {
            writeLog("[DOWNLOAD] Уровень 1: ${e.message}")
        }

        try {
            val proxyUrl = PROXY_URL + URLEncoder.encode(url, "UTF-8")
            val conn = URL(proxyUrl).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 60000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    FileOutputStream(dest).use { output -> input.copyTo(output) }
                }
                if (dest.length() > 1024) {
                    writeLog("[DOWNLOAD] Уровень 2 OK (${dest.length()} байт)")
                    return@withContext true
                }
            }
        } catch (e: Exception) {
            writeLog("[DOWNLOAD] Уровень 2: ${e.message}")
        }

        try {
            val proxyUrl = PROXY_URL + URLEncoder.encode(url, "UTF-8")
            val conn = URL(proxyUrl).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 60000
            conn.setRequestProperty("User-Agent", "curl/7.68.0")
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    FileOutputStream(dest).use { output -> input.copyTo(output) }
                }
                if (dest.length() > 1024) {
                    writeLog("[DOWNLOAD] Уровень 3 OK (${dest.length()} байт)")
                    return@withContext true
                }
            }
        } catch (e: Exception) {
            writeLog("[DOWNLOAD] Уровень 3: ${e.message}")
        }

        return@withContext false
    }

    suspend fun startCore(peer: String, password: String, hashes: String): Boolean = withContext(Dispatchers.IO) {
        if (getCorePath() == null) {
            if (!checkCore()) {
                return@withContext false
            }
        }

        val corePath = getCorePath() ?: return@withContext false

        val settingsFile = File(appDir, "settings.json")
        val settings = if (settingsFile.exists()) {
            try {
                org.json.JSONObject(settingsFile.readText())
            } catch (e: Exception) {
                org.json.JSONObject()
            }
        } else {
            org.json.JSONObject()
        }

        val workers = settings.optInt("workersPerHash", 9)
        val obfs = settings.optString("obfs", "video")
        val fingerprint = settings.optString("fingerprint", "firefox")
        val clientIds = settings.optString("clientIds", "8202606,6287487")
        val vkAuthMode = settings.optString("vkAuthMode", "vkcalls")
        val captchaMode = settings.optString("captchaMode", "auto")

        var deviceId = settings.optString("deviceId", "")
        if (deviceId.isBlank()) {
            deviceId = DeviceId.getOrCreate(context)
            DeviceId.syncToSettingsFile(context, deviceId)
            writeLog("[DEVICE] deviceId отсутствовал, восстановлен: $deviceId")
        }

        // total workers = workersPerHash * hashesCount (как на Desktop)
        val hashesList = hashes.split(",").filter { it.trim().isNotEmpty() }
        val hashesCount = if (hashesList.isEmpty()) 1 else minOf(hashesList.size, 6)
        val workersPerHash = if (workers < 9) 9 else workers
        val totalWorkers = workersPerHash * hashesCount

        val args = listOf(
            corePath,
            "-peer", peer,
            "-password", password,
            "-vk", hashes,
            "-n", totalWorkers.toString(),
            "-listen", "127.0.0.1:52230",
            "-obfs", obfs,
            "-fingerprint", fingerprint,
            "-client-ids", clientIds,
            "-vk-auth-mode", vkAuthMode,
            "-captcha-mode", captchaMode,
            "-device-id", deviceId
        )

        try {
            // Очищаем лог ядра перед новым запуском.
            logsFile.writeText("")

            val processBuilder = ProcessBuilder(args)
            processBuilder.redirectErrorStream(true)
            processBuilder.directory(coreDir)

            coreProcess = processBuilder.start()
            isRunning = true

            val process = coreProcess
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    process?.inputStream?.bufferedReader()?.use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            line?.let {
                                synchronized(this@CoreManager) {
                                    logsFile.appendText(it + "\n")
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    // Процесс завершён
                }
            }

            writeLog("[CORE] Процесс запущен: ${args.joinToString(" ")}")
            return@withContext true
        } catch (e: Exception) {
            writeLog("[CORE] Ошибка запуска: ${e.message}")
            return@withContext false
        }
    }

    fun stopCore() {
        isRunning = false
        try {
            coreProcess?.destroy()
            coreProcess = null
            writeLog("[CORE] Процесс остановлен")
        } catch (e: Exception) {
            writeLog("[CORE] Ошибка остановки: ${e.message}")
        }
    }

    fun isRunning(): Boolean = isRunning

    private fun writeLog(message: String) {
        synchronized(this) {
            logsFile.appendText(message + "\n")
        }
    }
}
