// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SmartTunnelManager — встроенный Lua 5.1-рантайм для SmartTunnel на Android.
//
// Использует org.luaj:luaj-jse:3.0.1.
//
// Скрипт копируется из assets/SmartTunnel.lua в filesDir/SmartTunnel.lua
// при первом запуске, оттуда читается и запускается.

package com.lalune.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.*
import org.json.JSONObject
import org.luaj.vm2.Globals
import org.luaj.vm2.LuaError
import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import org.luaj.vm2.Varargs
import org.luaj.vm2.lib.VarArgFunction
import org.luaj.vm2.lib.jse.JsePlatform
import java.io.File

class SmartTunnelManager(private val context: Context) {

    companion object {
        private const val TAG = "SmartTunnel"
        private const val SCRIPT_NAME = "SmartTunnel.lua"
        private const val TICK_INTERVAL_MS = 1000L
        private const val LOG_LIMIT = 500
    }

    private val appDir: File by lazy { File(context.filesDir, "la-lune") }
    private val scriptFile: File by lazy { File(appDir, SCRIPT_NAME) }
    private val logsFile: File by lazy { File(appDir, "logs.log") }

    private var globals: Globals? = null
    private var tickJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    @Volatile
    private var running = false

    private val luaLogs = ArrayDeque<String>()

    @Volatile
    private var tunnelArgs: List<String> = emptyList()

    private val inMemorySettings = mutableMapOf<String, LuaValue>()

    @Synchronized
    fun start() {
        if (running) return

        try {
            ensureScriptExists()
        } catch (e: Exception) {
            Log.e(TAG, "Не удалось подготовить $SCRIPT_NAME: ${e.message}")
            return
        }

        val g = JsePlatform.standardGlobals()
        globals = g

        registerApi(g)

        try {
            val src = scriptFile.readText()
            g.load(src, SCRIPT_NAME).call()
        } catch (e: LuaError) {
            Log.e(TAG, "Ошибка загрузки $SCRIPT_NAME: ${e.message}")
            globals = null
            return
        } catch (e: Exception) {
            Log.e(TAG, "Ошибка чтения $SCRIPT_NAME: ${e.message}")
            globals = null
            return
        }

        callIfExists("on_load")

        running = true
        writeLog("[SMART-TUNNEL] Рантайм запущен")

        tickJob?.cancel()
        tickJob = scope.launch {
            while (isActive && running) {
                delay(TICK_INTERVAL_MS)
                if (!running) break
                callIfExists("on_tick")
            }
        }
    }

    @Synchronized
    fun stop() {
        if (!running) return
        running = false
        tickJob?.cancel()
        tickJob = null
        globals = null
        writeLog("[SMART-TUNNEL] Рантайм остановлен")
    }

    fun isRunning(): Boolean = running

    fun setArgs(args: List<String>) {
        tunnelArgs = args.toList()
    }

    fun getArgs(): List<String> = tunnelArgs

    // ============================================================
    //  Внутреннее
    // ============================================================

    private fun ensureScriptExists() {
        if (!appDir.exists()) appDir.mkdirs()
        context.assets.open(SCRIPT_NAME).use { input ->
            scriptFile.outputStream().use { output ->
                input.copyTo(output)
            }
        }
    }

    private fun callIfExists(name: String) {
        val g = globals ?: return
        try {
            val fn = g.get(name)
            if (!fn.isnil() && fn.isfunction()) {
                fn.call()
            }
        } catch (e: LuaError) {
            writeLog("[SMART-TUNNEL] Ошибка в $name: ${e.message}")
        } catch (e: Exception) {
            writeLog("[SMART-TUNNEL] Ошибка в $name: ${e.message}")
        }
    }

    private fun registerApi(g: Globals) {
        val tbl = LuaTable()
        g.set("smarttunnel", tbl)

        // --- smarttunnel.log(message) ---
        tbl.set("log", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val msg = args.arg(1).tojstring()
                appendLuaLog(msg)
                writeLog(msg)
                return LuaValue.NIL
            }
        })

        // --- smarttunnel.logs() ---
        tbl.set("logs", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val out = LuaTable()
                synchronized(luaLogs) {
                    var i = 1
                    for (line in luaLogs) {
                        out.set(i, LuaValue.valueOf(line))
                        i++
                    }
                }
                return out
            }
        })

        // --- smarttunnel.connect() ---
        tbl.set("connect", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                writeLog("[SMART-TUNNEL] connect() — пока не реализовано")
                return LuaValue.FALSE
            }
        })

        // --- smarttunnel.disconnect() ---
        tbl.set("disconnect", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                writeLog("[SMART-TUNNEL] disconnect() — пока не реализовано")
                return LuaValue.FALSE
            }
        })

        // --- smarttunnel.is_connected() ---
        tbl.set("is_connected", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val connected = readSettingBool("_connected", false)
                return LuaValue.valueOf(connected)
            }
        })

        // --- smarttunnel.set_args(table) ---
        tbl.set("set_args", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val t = args.arg(1)
                if (!t.istable()) return LuaValue.NIL
                val list = mutableListOf<String>()
                val table = t.checktable()
                var i = 1
                while (true) {
                    val v = table.get(i)
                    if (v.isnil()) break
                    list.add(v.tojstring())
                    i++
                }
                tunnelArgs = list
                return LuaValue.NIL
            }
        })

        // --- smarttunnel.get_args() ---
        tbl.set("get_args", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val out = LuaTable()
                tunnelArgs.forEachIndexed { idx, s ->
                    out.set(idx + 1, LuaValue.valueOf(s))
                }
                return out
            }
        })

        // --- smarttunnel.get_vk_creds() ---
        tbl.set("get_vk_creds", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val out = LuaTable()
                val token = readVkToken()
                out.set("token", LuaValue.valueOf(token))
                out.set("hashes", LuaValue.valueOf(""))
                out.set("userId", LuaValue.valueOf(""))
                out.set("expiresIn", LuaValue.valueOf(0))
                return out
            }
        })

        // --- smarttunnel.get_setting(key) ---
        tbl.set("get_setting", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val key = args.arg(1).tojstring()
                return readSetting(key)
            }
        })

        // --- smarttunnel.set_setting(key, value) ---
        tbl.set("set_setting", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val key = args.arg(1).tojstring()
                val value = args.arg(2)
                writeSettingInMemory(key, value)
                return LuaValue.NIL
            }
        })
    }

    private fun appendLuaLog(msg: String) {
        synchronized(luaLogs) {
            luaLogs.addLast(msg)
            while (luaLogs.size > LOG_LIMIT) luaLogs.removeFirst()
        }
    }

    private fun writeLog(msg: String) {
        synchronized(this) {
            try {
                logsFile.appendText(msg + "\n")
            } catch (_: Exception) {}
        }
        Log.d(TAG, msg)
    }

    // ============================================================
    //  Чтение/запись настроек
    // ============================================================

    private fun readSetting(key: String): LuaValue {
        inMemorySettings[key]?.let { return it }
        return try {
            val settingsFile = File(appDir, "settings.json")
            if (!settingsFile.exists()) return LuaValue.NIL
            val json = JSONObject(settingsFile.readText())
            if (!json.has(key)) return LuaValue.NIL
            when (val v = json.get(key)) {
                is Boolean -> LuaValue.valueOf(v)
                is Int -> LuaValue.valueOf(v)
                is Long -> LuaValue.valueOf(v.toDouble())
                is Double -> LuaValue.valueOf(v)
                is String -> LuaValue.valueOf(v)
                else -> LuaValue.valueOf(v.toString())
            }
        } catch (_: Exception) {
            LuaValue.NIL
        }
    }

    private fun writeSettingInMemory(key: String, value: LuaValue) {
        inMemorySettings[key] = value
    }

    private fun readSettingBool(key: String, default: Boolean): Boolean {
        val v = readSetting(key)
        return if (v.isboolean()) v.toboolean() else default
    }

    private fun readVkToken(): String {
        return try {
            val tokenFile = File(appDir, "token.json")
            if (!tokenFile.exists()) return ""
            val json = JSONObject(tokenFile.readText())
            json.optString("Token", "")
        } catch (_: Exception) {
            ""
        }
    }
}
