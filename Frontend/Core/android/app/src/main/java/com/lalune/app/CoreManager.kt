// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// CoreManager — управление нативным ядром CSQTT на Android.
//
// Ядро (libclient-android-<abi>.so) поставляется ВНУТРИ APK,
// в lib/<abi>/ (jniLibs, упакованные Gradle'ом). Запускать его
// напрямую из nativeLibraryDir нельзя: на Android 10+ SELinux
// и W^X запрещают execve() файлов из /data/app/.../lib/.
//
// Поэтому при первом запуске мы копируем .so в filesDir/la-lune/core/,
// выставляем права 0755 и запускаем оттуда. Это стандартный подход
// для VPN-клиентов (Clash, sing-box, Xray и т.д.).

package com.lalune.app

import android.content.Context
import android.system.Os
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

class CoreManager(private val context: Context) {

    companion object {
        private const val TAG = "CoreManager"
    }

    private val appDir: File by lazy { File(context.filesDir, "la-lune") }
    private val coreDir: File by lazy { File(appDir, "core") }

    val logsFile: File by lazy { File(appDir, "logs.log") }

    private val latestFile: File by lazy { File(appDir, "LATEST") }
    private var coreProcess: Process? = null
    private var isRunning = false

    /**
     * Имя нативного ядра внутри APK, в зависимости от ABI устройства.
     * Gradle кладёт файлы из src/main/jniLibs/<abi>/ в lib/<abi>/
     * внутри APK, и Android распаковывает их в nativeLibraryDir.
     */
    fun getCoreName(): String? {
        val arch = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
        return when {
            arch.contains("arm64") -> "libclient-android-arm64-v8a.so"
            arch.contains("arm") -> "libclient-android-armeabi-v7a.so"
            arch.contains("x86_64") -> "libclient-android-x86_64.so"
            else -> null
        }
    }

    /** Путь к ядру, извлечённому из APK в filesDir (откуда можно exec). */
    fun getCorePath(): String? {
        val coreName = getCoreName() ?: return null
        val file = File(coreDir, coreName)
        return if (file.exists()) file.absolutePath else null
    }

    /**
     * Копирует ядро из nativeLibraryDir (внутри APK) в filesDir,
     * выставляет права 0755. Идемпотентно: если файл уже скопирован
     * и его размер совпадает с исходным — ничего не делает.
     *
     * Возвращает true при успехе.
     */
    suspend fun ensureCoreExtracted(): Boolean = withContext(Dispatchers.IO) {
        val coreName = getCoreName()
        if (coreName == null) {
            writeLog("[CORE] Неизвестная ABI: ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
            return@withContext false
        }

        val srcFile = File(context.applicationInfo.nativeLibraryDir, coreName)
        if (!srcFile.exists()) {
            writeLog("[CORE] Ядро не найдено в APK: ${srcFile.absolutePath}")
            return@withContext false
        }

        coreDir.mkdirs()
        val dstFile = File(coreDir, coreName)

        // Если файл уже извлечён и совпадает по размеру — ничего не делаем.
        if (dstFile.exists() && dstFile.length() == srcFile.length()) {
            // Но права всё равно перепроверим — они могли слететь.
            try {
                Os.chmod(dstFile.absolutePath, 0b111101101) // 0755
            } catch (e: Exception) {
                Log.w(TAG, "chmod failed for existing core: ${e.message}")
            }
            writeLog("[CORE] Ядро уже извлечено: ${dstFile.absolutePath}")
            return@withContext true
        }

        writeLog("[CORE] Извлекаю ядро из APK: $coreName")
        try {
            srcFile.inputStream().use { input ->
                FileOutputStream(dstFile).use { output ->
                    input.copyTo(output)
                }
            }

            // chmod 0755 через android.system.Os — надёжнее, чем
            // File.setExecutable(true, false), который может не выставить
            // execute-бит для группы/остальных.
            Os.chmod(dstFile.absolutePath, 0b111101101) // 0755

            writeLog("[CORE] Ядро извлечено: ${dstFile.absolutePath} " +
                     "(${dstFile.length()} байт)")
            return@withContext true
        } catch (e: Exception) {
            writeLog("[CORE] Ошибка извлечения ядра: ${e.message}")
            dstFile.delete()
            return@withContext false
        }
    }

    /** Убедиться, что ядро доступно; при необходимости — извлечь из APK. */
    suspend fun checkCore(): Boolean = withContext(Dispatchers.IO) {
        // Уже есть готовый исполняемый файл — ок.
        val existing = getCorePath()
        if (existing != null) {
            writeLog("[CORE] Ядро найдено: $existing")
            return@withContext true
        }
        // Иначе — извлекаем из APK.
        return@withContext ensureCoreExtracted()
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

        var workers = settings.optInt("workers", 9)
        if (workers < 1) workers = 1
        if (workers > 127) workers = 127

        val obfs = settings.optString("obfs", "video")
        val fingerprint = settings.optString("fingerprint", "firefox")
        val clientIds = settings.optString("clientIds", "8202606,6287487")
        val vkAuthMode = settings.optString("vkAuthMode", "vkcalls")
        val captchaMode = settings.optString("captchaMode", "auto")

        var deviceId = settings.optString("deviceId", "")
        if (deviceId.isBlank()) {
            deviceId = DeviceId.getOrCreate(context)
            DeviceId.syncToSettingsFile(context, deviceId)
        }

        val args = listOf(
            corePath,
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

        try {
            logsFile.writeText("")

            val processBuilder = ProcessBuilder(args)
            processBuilder.redirectErrorStream(true)
            processBuilder.directory(coreDir)

            coreProcess = processBuilder.start()
            isRunning = true

            val process = coreProcess
            kotlinx.coroutines.CoroutineScope(Dispatchers.IO).launch {
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
                }
            }

            writeLog("[CORE] Процесс запущен: $corePath")
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
