// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Lua-рантайм для SmartTunnel + csqtt_decode (Android).
//
// Использует LuaJ (org.luaj:luaj-jse:3.0.1) — чистый Java-интерпретатор
// Lua 5.2, работает на Android без NDK/JNI.

package com.lalune.lalune

import android.content.Context
import android.util.Log
import org.luaj.vm2.Globals
import org.luaj.vm2.LuaError
import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import org.luaj.vm2.lib.OneArgFunction
import org.luaj.vm2.lib.TwoArgFunction
import org.luaj.vm2.lib.ZeroArgFunction
import org.luaj.vm2.lib.jse.JsePlatform
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.zip.Inflater

class LuaRuntime(
    private val context: Context,
    private val appDir: File,
    private val settingsProvider: () -> org.json.JSONObject,
    private val settingsSetter: (String, Any?) -> Unit,
    private val logFn: (String) -> Unit,
    private val logsFn: () -> List<String>,
    private val vkTokenFn: () -> String?,
    private val vpnRunningFn: () -> Boolean,
) {
    companion object {
        private const val TAG = "LaLune-Lua"
        private const val ASSET_SMART = "SmartTunnel.lua"
        private const val ASSET_DECODE = "csqtt_decode.lua"
    }

    @Volatile private var globals: Globals? = null
    private var ticker: ScheduledExecutorService? = null

    @Volatile var smarttunnelRunning: Boolean = false

    fun init() {
        val g = JsePlatform.standardGlobals()

        registerZlib(g)

        val st = LuaTable()
        registerSmarttunnelApi(g, st)
        g.set("smarttunnel", st)

        val decodeSrc = loadOrExtractAsset(ASSET_DECODE)
        if (decodeSrc != null) {
            try {
                val chunk = g.load(decodeSrc, "csqtt_decode")
                val module = chunk.call()
                val packageTable = g.get("package")
                if (packageTable.istable()) {
                    packageTable.get("loaded").set("csqtt_decode", module)
                }
            } catch (e: LuaError) {
                Log.e(TAG, "csqtt_decode.lua load error: ${e.message}", e)
                logFn("[LUA] csqtt_decode load error: ${e.message}")
            }
        } else {
            Log.w(TAG, "csqtt_decode.lua not found (assets + appDir)")
        }

        val smartSrc = loadOrExtractAsset(ASSET_SMART)
        if (smartSrc != null) {
            try {
                g.load(smartSrc, "SmartTunnel").call()
            } catch (e: LuaError) {
                Log.e(TAG, "SmartTunnel.lua load error: ${e.message}", e)
                logFn("[LUA] SmartTunnel load error: ${e.message}")
            }
        } else {
            Log.w(TAG, "SmartTunnel.lua not found (assets + appDir)")
        }

        globals = g

        callOptional("on_load")
        startTicker()

        Log.i(TAG, "[LUA] runtime initialized (LuaJ)")
        logFn("[LUA] runtime initialized (LuaJ)")
    }

    fun destroy() {
        ticker?.shutdownNow()
        ticker = null
        globals = null
    }

    // ============================================================
    //  API
    // ============================================================

    private fun registerSmarttunnelApi(g: Globals, st: LuaTable) {
        st.set("log", object : OneArgFunction() {
            override fun call(arg: LuaValue): LuaValue {
                logFn("[LUA] ${arg.tojstring()}")
                return LuaValue.NIL
            }
        })

        st.set("logs", object : ZeroArgFunction() {
            override fun call(): LuaValue {
                val arr = LuaTable()
                logsFn().takeLast(200).forEachIndexed { i, line ->
                    arr.set(i + 1, LuaValue.valueOf(line))
                }
                return arr
            }
        })

        st.set("connect", object : ZeroArgFunction() {
            override fun call(): LuaValue {
                logFn("[LUA] smarttunnel.connect() called (noop)")
                return LuaValue.FALSE
            }
        })

        st.set("disconnect", object : ZeroArgFunction() {
            override fun call(): LuaValue {
                logFn("[LUA] smarttunnel.disconnect() called (noop)")
                return LuaValue.TRUE
            }
        })

        st.set("is_connected", object : ZeroArgFunction() {
            override fun call(): LuaValue = LuaValue.valueOf(vpnRunningFn())
        })

        st.set("get_setting", object : OneArgFunction() {
            override fun call(arg: LuaValue): LuaValue {
                val key = arg.tojstring()
                val json = settingsProvider()
                if (!json.has(key)) return LuaValue.NIL
                return when (val v = json.get(key)) {
                    is String -> LuaValue.valueOf(v)
                    is Int -> LuaValue.valueOf(v)
                    is Long -> LuaValue.valueOf(v.toDouble())
                    is Double -> LuaValue.valueOf(v)
                    is Boolean -> LuaValue.valueOf(v)
                    else -> LuaValue.NIL
                }
            }
        })

        st.set("set_setting", object : TwoArgFunction() {
            override fun call(k: LuaValue, v: LuaValue): LuaValue {
                val key = k.tojstring()
                val value: Any? = when {
                    v.isstring() -> v.tojstring()
                    v.isnumber() -> v.todouble()
                    v.isboolean() -> v.toboolean()
                    else -> null
                }
                settingsSetter(key, value)
                return LuaValue.NIL
            }
        })

        st.set("get_vk_creds", object : ZeroArgFunction() {
            override fun call(): LuaValue {
                val t = LuaTable()
                vkTokenFn()?.let { t.set("token", LuaValue.valueOf(it)) }
                t.set("hashes", LuaValue.valueOf(""))
                t.set("userId", LuaValue.valueOf(0))
                t.set("expiresIn", LuaValue.valueOf(0))
                return t
            }
        })
    }

    // ============================================================
    //  zlib.inflate
    //
    //  ВАЖНО: LuaJ 3.0.1 LuaError имеет конструкторы:
    //    LuaError(int), LuaError(String), LuaError(String, int)
    //  Конструктора LuaError(String, Throwable) НЕТ.
    //  Поэтому исходный exception логируем отдельно, а в Lua бросаем
    //  просто LuaError(String).
    // ============================================================

    private fun registerZlib(g: Globals) {
        val zlib = LuaTable()
        zlib.set("inflate", object : OneArgFunction() {
            override fun call(arg: LuaValue): LuaValue {
                val compressed = arg.checkstring().m_bytes
                val inflater = Inflater()
                try {
                    inflater.setInput(compressed, 0, compressed.size)
                    val out = java.io.ByteArrayOutputStream()
                    val buf = ByteArray(4096)
                    while (!inflater.finished()) {
                        val n = inflater.inflate(buf)
                        if (n == 0) {
                            if (inflater.needsInput() || inflater.needsDictionary()) break
                        } else {
                            out.write(buf, 0, n)
                        }
                    }
                    return LuaValue.valueOf(out.toByteArray())
                } catch (e: Exception) {
                    Log.w(TAG, "zlib.inflate failed: ${e.message}", e)
                    throw LuaError("inflate: ${e.message}")
                } finally {
                    inflater.end()
                }
            }
        })
        g.set("zlib", zlib)

        val packageTable = g.get("package")
        if (packageTable.istable()) {
            packageTable.get("loaded").set("zlib", zlib)
        }
    }

    // ============================================================
    //  Загрузка скриптов
    // ============================================================

    private fun loadOrExtractAsset(name: String): String? {
        val inAppDir = File(appDir, name)
        if (inAppDir.exists()) {
            return try {
                inAppDir.readText()
            } catch (e: Exception) {
                Log.w(TAG, "read $name from appDir failed: ${e.message}")
                null
            }
        }
        return try {
            val text = context.assets.open(name).bufferedReader().use { it.readText() }
            try {
                inAppDir.parentFile?.mkdirs()
                inAppDir.writeText(text)
            } catch (_: Exception) {}
            text
        } catch (_: Exception) {
            null
        }
    }

    // ============================================================
    //  on_log / on_tick / on_connect / on_disconnect / on_load
    // ============================================================

    private fun callOptional(name: String) {
        val g = globals ?: return
        try {
            val f = g.get(name)
            if (f.isfunction()) f.call()
        } catch (e: LuaError) {
            Log.w(TAG, "$name error: ${e.message}")
            logFn("[LUA] $name error: ${e.message}")
        }
    }

    fun onLog(line: String) {
        if (!smarttunnelRunning) return
        val g = globals ?: return
        try {
            val f = g.get("on_log")
            if (f.isfunction()) f.call(LuaValue.valueOf(line))
        } catch (_: LuaError) {}
    }

    fun onConnect() {
        smarttunnelRunning = true
        callOptional("on_connect")
    }

    fun onDisconnect() {
        smarttunnelRunning = false
        callOptional("on_disconnect")
    }

    private fun startTicker() {
        ticker?.shutdownNow()
        ticker = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "lalune-lua-tick").apply { isDaemon = true }
        }
        ticker?.scheduleAtFixedRate({
            if (!smarttunnelRunning) return@scheduleAtFixedRate
            val g = globals ?: return@scheduleAtFixedRate
            try {
                val f = g.get("on_tick")
                if (f.isfunction()) f.call()
            } catch (e: LuaError) {
                Log.w(TAG, "on_tick error: ${e.message}")
            }
        }, 1, 1, TimeUnit.SECONDS)
    }

    // ============================================================
    //  csqtt_decode
    // ============================================================

    class CsqttDecoded(
        val protocol: String,
        val peer: String,
        val host: String,
        val port: String,
        val password: String,
        val hashes: String,
        val name: String,
        val rawLink: String,
    )

    fun decodeCsqttLink(link: String): CsqttDecoded? {
        val g = globals ?: return null
        return try {
            val packageTable = g.get("package")
            if (!packageTable.istable()) return null
            val loaded = packageTable.get("loaded")
            val module = loaded.get("csqtt_decode")
            if (module.isnil()) return null
            val parse = module.get("parse_csqtt_link")
            if (!parse.isfunction()) return null

            val result = parse.call(LuaValue.valueOf(link))
            if (!result.istable()) return null

            CsqttDecoded(
                protocol = result.get("protocol").optjstring("CSQTT"),
                peer = result.get("peer").optjstring(""),
                host = result.get("host").optjstring(""),
                port = result.get("port").optjstring(""),
                password = result.get("password").optjstring(""),
                hashes = result.get("hashes").optjstring(""),
                name = result.get("name").optjstring(""),
                rawLink = result.get("raw_link").optjstring(link),
            )
        } catch (e: LuaError) {
            Log.w(TAG, "csqtt_decode error: ${e.message}")
            null
        } catch (e: Exception) {
            Log.w(TAG, "csqtt_decode error: ${e.message}")
            null
        }
    }
}
