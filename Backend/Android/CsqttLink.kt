// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Мост к бинарнику `csqtt-link`, запускаемому через ProcessBuilder.
//
// Бинарник лежит в `nativeLibraryDir/libcsqtt-link.so`
// (имя `.so` обязательно, чтобы Gradle упаковал файл в APK —
// это ELF-бинарник, не shared library; APK-упаковщик требует
// расширение `.so` для файлов из jniLibs).
//
// Запуск: ProcessBuilder(nativePath, "--json", link)
//   — stdout: JSON или human-readable
//   — exit code: 0 = OK, 1 = ошибка парсинга, 2 = usage
//
// Не JNI, не System.loadLibrary — просто ELF subprocess.

package com.lalune.lalune

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

object CsqttLink {
    private const val TAG = "LaLune-CsqttLink"

    @Volatile private var nativePath: String? = null
    @Volatile private var probed = false
    @Volatile private var unavailable = false

    /**
     * Находит путь к `libcsqtt-link.so` в nativeLibraryDir.
     * Возвращает null, если файла нет (старый APK без бинарника).
     */
    fun ensureAvailable(context: Context): String? {
        if (probed) {
            return if (unavailable) null else nativePath
        }
        probed = true

        val candidates = listOf(
            "libcsqtt-link.so",
            "libcsqtt_link.so",
            "csqtt-link",
            "libcsqtt-link",
        )
        val dir = File(context.applicationInfo.nativeLibraryDir)
        for (name in candidates) {
            val f = File(dir, name)
            if (f.exists() && f.canExecute()) {
                nativePath = f.absolutePath
                Log.i(TAG, "found native binary: ${f.absolutePath} (${f.length()} bytes)")
                return nativePath
            }
        }

        // На всякий случай — поискать в filesDir (на случай, если APK
        // распаковал не туда, или пользователь положил руками).
        val filesDir = File(context.filesDir, "la-lune")
        for (name in candidates) {
            val f = File(filesDir, name)
            if (f.exists() && f.canExecute()) {
                nativePath = f.absolutePath
                Log.i(TAG, "found native binary (filesDir): ${f.absolutePath}")
                return nativePath
            }
        }

        Log.w(TAG, "csqtt-link binary not found in ${dir.absolutePath}")
        unavailable = true
        return null
    }

    /**
     * Парсит ссылку через csqtt-link. Возвращает JSONObject или null.
     *
     * Запускает: `<nativePath> --json <link>`
     * Парсит stdout как JSON.
     */
    fun parse(context: Context, link: String): JSONObject? {
        val path = ensureAvailable(context) ?: return null
        return try {
            val result = runNative(path, listOf("--json", link), timeoutMs = 10_000)
            if (result == null) {
                Log.w(TAG, "native process returned null")
                return null
            }
            if (result.exitCode != 0) {
                Log.w(TAG, "native exit=${result.exitCode} stderr=${result.stderr.take(200)}")
                return null
            }
            val json = JSONObject(result.stdout)
            if (json.optBoolean("ok", false)) json else {
                Log.w(TAG, "native returned ok=false: ${json.optString("error", "")}")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "parse failed: ${e.message}", e)
            null
        }
    }

    data class ProcessResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
    )

    private fun runNative(
        path: String,
        args: List<String>,
        timeoutMs: Long,
    ): ProcessResult? {
        val cmd = mutableListOf(path)
        cmd.addAll(args)

        return try {
            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(false)
            val proc = pb.start()

            // Пишем stdin пустым — бинарник читает аргументы, не stdin.
            try { proc.outputStream.close() } catch (_: Exception) {}

            val stdout = StringBuilder()
            val stderr = StringBuilder()

            val tOut = Thread {
                BufferedReader(InputStreamReader(proc.inputStream)).use { r ->
                    var line: String?
                    while (r.readLine().also { line = it } != null) {
                        stdout.append(line).append('\n')
                    }
                }
            }
            val tErr = Thread {
                BufferedReader(InputStreamReader(proc.errorStream)).use { r ->
                    var line: String?
                    while (r.readLine().also { line = it } != null) {
                        stderr.append(line).append('\n')
                    }
                }
            }
            tOut.start()
            tErr.start()

            val finished = proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                proc.destroyForcibly()
                Log.w(TAG, "native process timeout after ${timeoutMs}ms")
                return null
            }

            tOut.join(1000)
            tErr.join(1000)

            ProcessResult(
                exitCode = proc.exitValue(),
                stdout = stdout.toString().trim(),
                stderr = stderr.toString().trim(),
            )
        } catch (e: Exception) {
            Log.w(TAG, "runNative failed: ${e.message}", e)
            null
        }
    }
}
