package com.lalune.app

import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlinx.coroutines.*
import java.io.BufferedReader
import java.io.InputStreamReader

class TermuxManager(private val context: Context) {
    private val appDir: File by lazy { File(context.filesDir, "la-lune") }
    private val coreDir: File by lazy { File(appDir, "core") }
    private val logsFile: File by lazy { File(appDir, "logs.txt") }
    private val latestFile: File by lazy { File(appDir, "LATEST") }
    private val coreLockFile: File by lazy { File(appDir, "core.lock") }
    
    private val LATEST_URL = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
    private val CORE_URL_TEMPLATE = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
    private val PROXY_URL = "http://31.77.148.203:8855/?url="
    private val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    suspend fun ensureCore(): Boolean = withContext(Dispatchers.IO) {
        val arch = getArch()
        if (arch == null) {
            writeLog("[ERROR] Не удалось определить архитектуру")
            return@withContext false
        }
        
        val coreName = when {
            arch.contains("arm64") -> "client-linux-arm64"
            arch.contains("arm") -> "client-linux-armv7"
            arch.contains("x86_64") -> "client-linux-x86_64"
            else -> return@withContext false
        }
        
        val coreFile = File(coreDir, coreName)
        if (coreFile.exists() && coreFile.length() > 1024) {
            writeLog("[CORE] Ядро уже существует: ${coreFile.absolutePath}")
            return@withContext true
        }

        writeLog("[CORE] Скачивание ядра для архитектуры: $arch ($coreName)")
        
        // Трёхуровневая система загрузки
        val version = fetchLatestVersion()
        if (version == null) {
            writeLog("[ERROR] Не удалось получить LATEST")
            return@withContext false
        }
        
        val url = String.format(CORE_URL_TEMPLATE, version, coreName)
        writeLog("[CORE] Скачивание: $url")
        
        if (!downloadCore(url, coreFile)) {
            writeLog("[ERROR] Не удалось скачать ядро")
            return@withContext false
        }
        
        // Сохраняем версию
        latestFile.writeText(version)
        
        // Делаем исполняемым
        coreFile.setExecutable(true, false)
        writeLog("[CORE] Ядро готово: ${coreFile.absolutePath}")
        
        return@withContext true
    }
    
    private suspend fun fetchLatestVersion(): String? = withContext(Dispatchers.IO) {
        // Уровень 1: прямой запрос
        try {
            val conn = URL(LATEST_URL).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 30000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode == 200) {
                return@withContext BufferedReader(InputStreamReader(conn.inputStream)).readText().trim()
            }
        } catch (e: Exception) {
            writeLog("[NET] Уровень 1 ошибка: ${e.message}")
        }
        
        // Уровень 2: через прокси
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
            writeLog("[NET] Уровень 2 ошибка: ${e.message}")
        }
        
        // Уровень 3: прокси с curl User-Agent
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
            writeLog("[NET] Уровень 3 ошибка: ${e.message}")
        }
        
        return@withContext null
    }
    
    private suspend fun downloadCore(url: String, dest: File): Boolean = withContext(Dispatchers.IO) {
        // Уровень 1: прямой
        try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 60000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    FileOutputStream(dest).use { output ->
                        input.copyTo(output)
                    }
                }
                if (dest.length() > 1024) return@withContext true
            }
        } catch (e: Exception) {
            writeLog("[DOWNLOAD] Уровень 1 ошибка: ${e.message}")
        }
        
        // Уровень 2: через прокси
        try {
            val proxyUrl = PROXY_URL + URLEncoder.encode(url, "UTF-8")
            val conn = URL(proxyUrl).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 60000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    FileOutputStream(dest).use { output ->
                        input.copyTo(output)
                    }
                }
                if (dest.length() > 1024) return@withContext true
            }
        } catch (e: Exception) {
            writeLog("[DOWNLOAD] Уровень 2 ошибка: ${e.message}")
        }
        
        // Уровень 3: прокси с curl User-Agent
        try {
            val proxyUrl = PROXY_URL + URLEncoder.encode(url, "UTF-8")
            val conn = URL(proxyUrl).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 60000
            conn.setRequestProperty("User-Agent", "curl/7.68.0")
            if (conn.responseCode == 200) {
                conn.inputStream.use { input ->
                    FileOutputStream(dest).use { output ->
                        input.copyTo(output)
                    }
                }
                if (dest.length() > 1024) return@withContext true
            }
        } catch (e: Exception) {
            writeLog("[DOWNLOAD] Уровень 3 ошибка: ${e.message}")
        }
        
        return@withContext false
    }
    
    private fun getArch(): String? {
        return android.os.Build.SUPPORTED_ABIS.firstOrNull()
    }
    
    fun runCoreViaTermux(peer: String, password: String, hashes: String, workers: Int): Boolean {
        val corePath = getCorePath() ?: return false
        
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
        
        val obfs = settings.optString("obfs", "video")
        val fingerprint = settings.optString("fingerprint", "firefox")
        val clientIds = settings.optString("clientIds", "8202606,6287487")
        val vkAuthMode = settings.optString("vkAuthMode", "vkcalls")
        val captchaMode = settings.optString("captchaMode", "auto")
        val deviceId = settings.optString("deviceId", "")
        
        // Формируем аргументы
        val args = listOf(
            "-peer", peer,
            "-password", password,
            "-vk", hashes,
            "-n", workers.toString(),
            "-listen", "127.0.0.1:52230",
            "-obfs", obfs,
            "-fingerprint", fingerprint,
            "-client-ids", clientIds,
            "-vk-auth-mode", vkAuthMode,
            "-captcha-mode", captchaMode,
            "-device-id", deviceId
        )
        
        // Создаём команду с перенаправлением логов
        val cmd = "${corePath} ${args.joinToString(" ")} > ${logsFile.absolutePath} 2>&1 &"
        
        // Используем Intent для Termux:API
        try {
            val intent = Intent("com.termux.RUN_COMMAND")
            intent.putExtra("com.termux.RUN_COMMAND_PATH", "/system/bin/sh")
            intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", cmd))
            intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            intent.putExtra("com.termux.RUN_COMMAND_WORKDIR", coreDir.absolutePath)
            
            context.startActivity(intent)
            writeLog("[TERMUX] Команда отправлена: $cmd")
            return true
        } catch (e: Exception) {
            writeLog("[TERMUX] Ошибка запуска: ${e.message}")
            return false
        }
    }
    
    fun stopCore() {
        try {
            val intent = Intent("com.termux.RUN_COMMAND")
            intent.putExtra("com.termux.RUN_COMMAND_PATH", "/system/bin/sh")
            intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", "pkill -f 'client-linux'"))
            intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            context.startActivity(intent)
            writeLog("[TERMUX] Команда остановки отправлена")
        } catch (e: Exception) {
            writeLog("[TERMUX] Ошибка остановки: ${e.message}")
        }
    }
    
    fun getCorePath(): String? {
        val arch = getArch() ?: return null
        val coreName = when {
            arch.contains("arm64") -> "client-linux-arm64"
            arch.contains("arm") -> "client-linux-armv7"
            arch.contains("x86_64") -> "client-linux-x86_64"
            else -> return null
        }
        
        val coreFile = File(coreDir, coreName)
        return if (coreFile.exists()) coreFile.absolutePath else null
    }
    
    fun getLogs(): String {
        return if (logsFile.exists()) {
            logsFile.readText()
        } else {
            ""
        }
    }
    
    fun clearLogs() {
        logsFile.writeText("")
    }
    
    private fun writeLog(message: String) {
        logsFile.appendText(message + "\n")
        Log.d("LaLune", message)
    }
}
