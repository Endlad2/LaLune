// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Мост к FreeTurn AAR (gomobile bind).
//
// AAR скачивается CI из релиза:
//   https://github.com/hackdiaz-dev/free-turn-proxy/releases/latest/download/freeturn.aar
// и лежит в Frontend/android/app/libs/freeturn.aar.
//
// Пакет Java: com.freeturn.core.mobile.Mobile
//   (gomobile bind -javapkg com.freeturn.core ./mobile)
//
// ВАЖНО: gomobile генерирует Java-методы в lowerCamelCase,
// а Go-интерфейсы — с теми же именами, что в Go, но в lowerCamelCase:
//
//   EventSink:
//     onState(state: String, streams: Long, total: Long, errMsg: String)
//     onLog(level: String, msg: String, unixMillis: Long)
//     onCaptcha(url: String, manual: Boolean)
//
//   Protector:
//     protect(fd: Long): Boolean
//
// Если компилятор ругается «'OnState' overrides nothing» — значит
// AAR собран другой версией gomobile или переименовал методы иначе.
// Проверь `unzip -l freeturn.aar | grep classes.jar` и `javap` по нему.
//
// API из /mobile/README.md upstream:
//   Mobile.start(configJSON: String)                     — режим прокси (UDP-relay)
//   Mobile.startTunnel(configJSON: String, tunFD: Long)  — прокси + WireGuard/AmneziaWG
//   Mobile.startDirectTunnel(wgText: String, mtu: Long, tunFD: Long)
//   Mobile.restart(configJSON: String, tunFD: Long)
//   Mobile.stop()
//   Mobile.getState(): Snapshot
//   Mobile.tunnelStats(): TunnelSnapshot
//   Mobile.parseTunnelConfig(wgText: String, mtu: Long): TunnelParams
//   Mobile.setEventSink(sink: EventSink)
//   Mobile.setProtect(p: Protector)
//   Mobile.defaultConfigJSON(): String
//   Mobile.validateConfig(json: String): String
//   Mobile.configToArgs(json: String): String
//   Mobile.setLogBuffer(enabled: Boolean)
//   Mobile.dumpLogs(): String
//   Mobile.clearLogs()
//   Mobile.version(): String
//   Mobile.wake()
//   Mobile.reconnect()
//   Mobile.setDNSServers(servers: String)
//   Mobile.setStateDir(path: String)
//
// Go: int → Java long.

package com.lalune.lalune

import android.net.VpnService
import android.util.Log
import com.freeturn.core.mobile.EventSink
import com.freeturn.core.mobile.Mobile
import com.freeturn.core.mobile.Protector
import com.freeturn.core.mobile.Snapshot
import com.freeturn.core.mobile.TunnelParams
import com.freeturn.core.mobile.TunnelSnapshot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class FreeTurnManager(
    private val context: android.content.Context,
    private val appDir: File,
    private val logFn: (String) -> Unit,
    private val stateFn: (connected: Boolean, streams: Int, total: Int) -> Unit,
) {
    companion object {
        private const val TAG = "LaLune-FreeTurn"

        // FreeTurn в режиме Mobile.start(configJson) (без tunFd) слушает
        // proxy.listen из JSON. По docs/quickstart.md upstream — 127.0.0.1:9000.
        const val FREETURN_LISTEN_PORT = 9000
    }

    private var eventSink: EventSinkImpl? = null
    private var protector: ProtectorImpl? = null
    @Volatile private var vpnService: VpnService? = null
    @Volatile private var running = false

    init {
        // Android app-uid не может писать в ~/.config и cwd:
        // client_config.json и vk_persona.json идут в filesDir.
        Mobile.setStateDir(appDir.absolutePath)
        Mobile.setLogBuffer(true)

        protector = ProtectorImpl { fd -> protectFd(fd) }
        Mobile.setProtect(protector!!)

        eventSink = EventSinkImpl(logFn, stateFn)
        Mobile.setEventSink(eventSink!!)

        logFn("[FREETURN] AAR version=${runCatching { Mobile.version() }.getOrDefault("?")}")
    }

    /**
     * Привязывает работающий VpnService, чтобы Protector мог звать protect(fd).
     * Вызывать из LaLuneVpnService.onCreate().
     */
    fun attachVpnService(service: VpnService?) {
        vpnService = service
    }

    private fun protectFd(fd: Long): Boolean {
        val svc = vpnService ?: return false
        return try {
            svc.protect(fd.toInt())
        } catch (e: Throwable) {
            Log.w(TAG, "[FREETURN] protect(fd=$fd): ${e.message}")
            false
        }
    }

    fun isAvailable(): Boolean = try {
        Mobile.defaultConfigJSON().isNotEmpty()
    } catch (_: Throwable) {
        false
    }

    /**
     * Запускает FreeTurn в режиме relay-only (без встроенного WG).
     *
     * AAR слушает UDP на 127.0.0.1:${FREETURN_LISTEN_PORT}.
     * TUN поднимает LaLuneVpnService и мостит его на этот порт — так же,
     * как для CSQTT на 5399.
     */
    fun startRelayOnly(
        peer: String,
        link: String,
        obfProfile: String,
        obfKey: String,
        clientId: String,
        n: Int,
        dnsMode: String,
        dnsServers: String,
        mode: String,
    ): Boolean {
        if (running) {
            Log.w(TAG, "already running")
            return false
        }

        val configJson = buildConfigJson(
            peer = peer,
            link = link,
            obfProfile = obfProfile,
            obfKey = obfKey,
            clientId = clientId,
            n = n,
            dnsMode = dnsMode,
            dnsServers = dnsServers,
            mode = mode,
        )
        Log.i(TAG, "[FREETURN] config: ${maskKey(configJson)}")

        val err = runCatching { Mobile.validateConfig(configJson) }.getOrElse { it.message ?: "" }
        if (err.isNotEmpty()) {
            Log.e(TAG, "[FREETURN] validate: $err")
            logFn("[FREETURN] config error: $err")
            return false
        }

        return try {
            Mobile.start(configJson)
            running = true
            logFn("[FREETURN] started (listen 127.0.0.1:$FREETURN_LISTEN_PORT, mode=$mode)")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "[FREETURN] start failed: ${e.message}", e)
            logFn("[FREETURN] start failed: ${e.message}")
            running = false
            false
        }
    }

    /**
     * Запуск со встроенным WireGuard: AAR сам читает tun-дескриптор.
     * Используется, только если в freeturn:// пришёл wg-конфиг.
     */
    fun startTunnelWithWg(
        peer: String,
        link: String,
        obfProfile: String,
        obfKey: String,
        clientId: String,
        n: Int,
        dnsMode: String,
        dnsServers: String,
        wgText: String,
        mtu: Int,
        tunFd: Int,
    ): Boolean {
        if (running) return false
        if (tunFd <= 0) {
            logFn("[FREETURN] startTunnel: bad tun fd $tunFd")
            return false
        }

        val configJson = buildConfigJson(
            peer = peer,
            link = link,
            obfProfile = obfProfile,
            obfKey = obfKey,
            clientId = clientId,
            n = n,
            dnsMode = dnsMode,
            dnsServers = dnsServers,
            mode = "udp",
            wgText = wgText,
            mtu = mtu,
        )
        Log.i(TAG, "[FREETURN] tunnel config: ${maskKey(configJson)}")

        val err = runCatching { Mobile.validateConfig(configJson) }.getOrElse { it.message ?: "" }
        if (err.isNotEmpty()) {
            logFn("[FREETURN] config error: $err")
            return false
        }

        return try {
            Mobile.startTunnel(configJson, tunFd.toLong())
            running = true
            logFn("[FREETURN] tunnel started (tunFd=$tunFd)")
            true
        } catch (e: Throwable) {
            logFn("[FREETURN] tunnel start failed: ${e.message}")
            running = false
            false
        }
    }

    fun stop() {
        if (!running) return
        runCatching { Mobile.stop() }.onFailure { Log.w(TAG, "[FREETURN] stop: ${it.message}") }
        running = false
        logFn("[FREETURN] stopped")
    }

    fun restart(tunFd: Int) {
        if (!running) return
        runCatching { Mobile.restart("", tunFd.toLong()) }
            .onFailure { Log.w(TAG, "[FREETURN] restart: ${it.message}") }
    }

    fun reconnect() { runCatching { Mobile.reconnect() } }
    fun wake()      { runCatching { Mobile.wake() } }
    fun setDnsServers(servers: String) { runCatching { Mobile.setDNSServers(servers) } }

    fun state(): JSONObject = try {
        val s: Snapshot = Mobile.getState()
        JSONObject().apply {
            put("state", s.state)
            put("streams", s.streams)
            put("total", s.total)
            put("error", s.errMsg)
            put("txTotal", s.txTotal)
            put("rxTotal", s.rxTotal)
            put("txRate", s.txRate)
            put("rxRate", s.rxRate)
        }
    } catch (e: Throwable) {
        JSONObject().put("state", "error").put("error", e.message ?: "")
    }

    fun tunnelStats(): JSONObject = try {
        val t: TunnelSnapshot = Mobile.tunnelStats()
        JSONObject().apply {
            put("up", t.up)
            put("rxBytes", t.rxBytes)
            put("txBytes", t.txBytes)
            put("handshakeAgeSec", t.handshakeAgeSec)
        }
    } catch (e: Throwable) {
        JSONObject().put("up", false).put("error", e.message ?: "")
    }

    /** Параметры tun для VpnService.Builder; null — конфиг невалиден. */
    fun parseTunnelConfig(wgText: String, mtu: Int): JSONObject? = try {
        val p: TunnelParams = Mobile.parseTunnelConfig(wgText, mtu.toLong())
        JSONObject().apply {
            put("addresses", p.addresses)
            put("dns", p.dns)
            put("allowedIPs", p.allowedIPs)
            put("mtu", p.mtu)
        }
    } catch (e: Throwable) {
        Log.w(TAG, "[FREETURN] parseTunnelConfig: ${e.message}")
        null
    }

    fun dumpLogs(): String = runCatching { Mobile.dumpLogs() }.getOrDefault("")
    fun clearLogs() { runCatching { Mobile.clearLogs() } }

    // ============================================================
    //  JSON-конфиг по схеме /mobile/README.md upstream
    // ============================================================

    private fun buildConfigJson(
        peer: String,
        link: String,
        obfProfile: String,
        obfKey: String,
        clientId: String,
        n: Int,
        dnsMode: String,
        dnsServers: String,
        mode: String,
        wgText: String = "",
        mtu: Int = 1280,
    ): String {
        val turn = JSONObject().apply {
            put("n", n)
            put("transport", "tcp")
            put("host", "")
            put("port", "")
        }
        val proxy = JSONObject().apply {
            put("mode", if (mode == "tcp") "tcp" else "udp")
            put("listen", "127.0.0.1:$FREETURN_LISTEN_PORT")
        }
        val vk = JSONObject().apply {
            put("links", JSONArray().put(link))
            put("streamsPerCred", n)
            put("manualCaptcha", false)
            put("autoCaptcha", true)
            put("advancedCaptcha", false)
            put("platform", "mobile")
        }
        val obf = JSONObject().apply {
            put("profile", if (obfProfile.isBlank()) "rtpopus3" else obfProfile)
            put("key", obfKey)
            put("timingMs", 0)
        }
        val dns = JSONObject().apply {
            put("mode", if (dnsMode.isBlank()) "auto" else dnsMode)
            if (dnsServers.isNotBlank()) {
                put("servers", JSONArray(dnsServers.split(",").map { it.trim() }))
            } else {
                put("servers", JSONArray())
            }
        }
        val log = JSONObject().put("debug", false)

        // Встроенный WG (StartTunnel): tunnel.mode=wg/awg + текст конфига.
        // Relay-only (Start): mode=none.
        val tunnel = if (wgText.isNotBlank()) {
            JSONObject().apply {
                put("mode", "wg")
                put("config", wgText)
                put("mtu", mtu)
            }
        } else {
            JSONObject().apply {
                put("mode", "none")
                put("config", "")
                put("mtu", mtu)
            }
        }

        return JSONObject().apply {
            put("peer", peer)
            put("clientId", clientId)
            put("provider", "vk")
            put("turn", turn)
            put("proxy", proxy)
            put("vk", vk)
            put("obf", obf)
            put("dns", dns)
            put("log", log)
            put("tunnel", tunnel)
        }.toString()
    }

    private fun maskKey(json: String): String =
        json.replace(Regex("\"key\":\"[^\"]+\""), "\"key\":\"***\"")

    // ============================================================
    //  EventSink — AAR зовёт из фоновых горутин
    //
    //  gomobile генерирует Java-методы в lowerCamelCase:
    //    onState(state: String!, streams: Long, total: Long, errMsg: String!)
    //    onLog(level: String!, msg: String!, unixMillis: Long)
    //    onCaptcha(url: String!, manual: Boolean)
    //
    //  Go int -> Java long.
    // ============================================================

    private class EventSinkImpl(
        private val logFn: (String) -> Unit,
        private val stateFn: (Boolean, Int, Int) -> Unit,
    ) : EventSink {
        override fun onState(state: String?, streams: Long, total: Long, errMsg: String?) {
            val connected = state == "connected"
            stateFn(connected, streams.toInt(), total.toInt())
            if (!errMsg.isNullOrEmpty()) {
                logFn("[FREETURN] state=$state error=$errMsg")
            }
        }

        override fun onLog(level: String?, msg: String?, unixMillis: Long) {
            logFn("[FREETURN:$level] ${msg ?: ""}")
        }

        override fun onCaptcha(url: String?, manual: Boolean) {
            logFn("[FREETURN] captcha ${if (manual) "manual" else "auto"}: ${url ?: ""}")
        }
    }

    // ============================================================
    //  Protector — gomobile: protect(fd: Long): Boolean
    // ============================================================

    private class ProtectorImpl(
        private val protect: (Long) -> Boolean,
    ) : Protector {
        override fun protect(fd: Long): Boolean = protect(fd)
    }
}
