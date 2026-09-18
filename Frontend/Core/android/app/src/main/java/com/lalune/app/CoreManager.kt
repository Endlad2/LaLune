// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// CoreManager — управление нативным ядром CSQTT на Android.
//
// ВАЖНО: ядро (libclient-android-<abi>.so) запускается ПРЯМО из
// nativeLibraryDir, без копирования в filesDir и без chmod.
//
// Почему так работает:
//   - AndroidManifest.xml имеет extractNativeLibs="true", поэтому
//     Gradle упаковывает jniLibs/<abi>/*.so в APK, а система при
//     установке распаковывает их в /data/app/.../lib/<abi>/.
//   - targetSdk = 28 включает legacy-режим, в котором SELinux
//     разрешает execve() для файлов из nativeLibraryDir.
//   - android:debuggable="true" — второй рубеж: даже на новых
//     прошивках debuggable-приложениям разрешён execve из
//     app_data_file/apk_data_file.
//
// Логи ядра пишутся в filesDir/la-lune/logs.log; их читает
// LaLuneVpnService, чтобы понять, когда поднимать TUN.

package com.lalune.app

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

class CoreManager(private val context: Context) {

    companion object {
        private const val DEFAULT_WORKERS = 9
        private const val MIN_WORKERS = 1
        private const val MAX_WORKERS = 127
    }

    private val appDir: File by lazy { File(context.filesDir, "la-lune") }
    private val coreDir: File by lazy { File(appDir, "core") }

    val logsFile: File by lazy { File(appDir, "logs.log") }

    private var coreProcess: Process? = null
    private var isRunning = false

    /**
     * Имя ядра внутри APK, в зависимости от ABI устройства.
     * Gradle кладёт jniLibs/<abi>/libclient-android-<abi>.so в
     * lib/<abi>/ внутри APK, система распаковывает в nativeLibraryDir.
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

    /**
     * Путь к ядру — прямо в nativeLibraryDir.
     * Никакого копирования в filesDir: на targetSdk=28 + debuggable
     * Android разрешает execve оттуда (это старый проверенный путь).
     */
    fun getCorePath(): String? {
        val coreName = getCoreName() ?: return null
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val coreFile = File(nativeDir, coreName)
        return if (coreFile.exists()) coreFile.absolutePath else null
    }

    /**
     * Проверяет, что ядро доступно в nativeLibraryDir.
     * Если нет — пишет понятную диагностику в лог.
     */
    suspend fun checkCore(): Boolean = withContext(Dispatchers.IO) {
        val coreName = getCoreName()
        if (coreName == null) {
            writeLog("[CORE] Неизвестная ABI: ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
            return@withContext false
        }

        val nativeDir = context.applicationInfo.nativeLibraryDir
        val coreFile = File(nativeDir, coreName)

        writeLog("[CORE] nativeLibraryDir = $nativeDir")
        writeLog("[CORE] ищем: ${coreFile.absolutePath}")

        if (!coreFile.exists()) {
            writeLog("[CORE] Ядро НЕ найдено в nativeLibraryDir")
            writeLog("[CORE] SUPPORTED_ABIS = ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
            // Покажем, что вообще есть в nativeLibraryDir — для диагностики.
            try {
                File(nativeDir).listFiles()?.forEach { f ->
                    writeLog("[CORE]   ${f.name}  ${f.length()} bytes")
                }
            } catch (_: Exception) {}
            return@withContext false
        }

        writeLog("[CORE] Ядро найдено: ${coreFile.absolutePath} (${coreFile.length()} байт)")
        return@withContext true
    }

    /**
     * Запускает ядро из nativeLibraryDir.
     * Все аргументы — те же, что были в рабочем старом проекте.
     */
    suspend fun startCore(peer: String, password: String, hashes: String): Boolean =
        withContext(Dispatchers.IO) {
            if (!checkCore()) {
                writeLog("[CORE] startCore: ядро недоступно")
                return@withContext false
            }

            val corePath = getCorePath()
            if (corePath == null) {
                writeLog("[CORE] startCore: getCorePath() вернул null")
                return@withContext false
            }

            writeLog("[CORE] Запускаю: $corePath")

            val settingsFile = File(appDir, "settings.json")
            val settings = if (settingsFile.exists()) {
                try {
                    org.json.JSONObject(settingsFile.readText())
                } catch (_: Exception) {
                    org.json.JSONObject()
                }
            } else {
                org.json.JSONObject()
            }

            var workers = settings.optInt("workers", DEFAULT_WORKERS)
            if (workers < MIN_WORKERS) workers = MIN_WORKERS
            if (workers > MAX_WORKERS) workers = MAX_WORKERS

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
                processBuilder.directory(context.applicationInfo.nativeLibraryDir.let { File(it) })

                coreProcess = processBuilder.start()
                isRunning = true

                val process = coreProcess

                // Читаем stdout/stderr в фоне, пишем в logs.log.
                // LaLuneVpnService читает этот файл и реагирует на
                // TUNCONF: и [СТАТИСТИКА] Активных: N.
                Thread {
                    try {
                        process?.inputStream?.bufferedReader()?.use { reader ->
                            var line: String?
                            while (reader.readLine().also { line = it } != null) {
                                line?.let {
                                    synchronized(this@CoreManager) {
                                        try { logsFile.appendText(it + "\n") }
                                        catch (_: Exception) {}
                                    }
                                }
                            }
                        }
                    } catch (_: Exception) {
                        // Процесс закрылся — выходим.
                    }
                }.start()

                writeLog("[CORE] Процесс запущен: $corePath")
                return@withContext true
            } catch (e: Exception) {
                writeLog("[CORE] Ошибка запуска: ${e.javaClass.simpleName}: ${e.message}")
                writeLog("[CORE]   path=$corePath")
                writeLog("[CORE]   nativeLibDir=${context.applicationInfo.nativeLibraryDir}")
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
            try { logsFile.appendText(message + "\n") } catch (_: Exception) {}
        }
        android.util.Log.d("LaLune-Core", message)
    }
}
