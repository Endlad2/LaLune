// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VpnService с TUN + UDP-мост к ядру CSQTT.
//
// package = com.lalune.lalune — тот же, что у MainActivity и Backend.
//
// Порядок (как в Desktop):
//   1. Ядро запускается (уже запущено Backend'ом до startForegroundService).
//   2. Ждём в logs.log "Активных: N>0" ДВА тика подряд.
//   3. Только тогда поднимаем TUN + UDP-мост.
//
// Уведомление: отдельный тикер каждые 2 сек обновляет notification,
// чтобы статистика (Активных / Трафик) не "застывала".

package com.lalune.lalune

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import org.json.JSONArray
import org.json.JSONObject

class LaLuneVpnService : VpnService() {

    companion object {
        private const val TAG = "LaLune-VPN"
        private const val CHANNEL_ID = "lalune_vpn"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.lalune.lalune.STOP_FROM_NOTIFICATION"
        private const val CORE_PORT = 52230
        private const val DEFAULT_TUN_IP = "10.66.67.12"
        private const val DEFAULT_DNS_1 = "8.8.8.8"
        private const val DEFAULT_DNS_2 = "8.8.4.4"
        private const val MTU = 1300

        /** Периодичность обновления уведомления (2 сек). */
        private const val NOTIFICATION_TICK_MS = 2_000L

        const val ACTION_STATUS = "com.lalune.lalune.VPN_STATUS"
        const val EXTRA_CONNECTED = "connected"

        fun notifyStatus(ctx: Context, connected: Boolean) {
            val i = Intent(ACTION_STATUS).apply {
                setPackage(ctx.packageName)
                putExtra(EXTRA_CONNECTED, connected)
            }
            ctx.sendBroadcast(i)
        }
    }

    @Volatile private var detectedTunIP: String? = null
    @Volatile private var detectedDNS: String? = null
    @Volatile private var activeSessions: Int = 0
    @Volatile private var consecutiveActiveTicks: Int = 0
    @Volatile private var trafficMB: String = "0.00"

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var isRunning = false
    @Volatile private var tunEstablished = false
    @Volatile private var establishing = false

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var coreManager: CoreManager
    private var notificationTickerJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        coreManager = CoreManager(this)
        startForegroundCompat()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START" -> if (!isRunning) {
                isRunning = true
                startFlow()
            }
            "STOP", ACTION_STOP -> stopFlow()
        }
        return START_STICKY
    }

    private fun startFlow() {
        Log.d(TAG, "startFlow")
        scope.launch {
            val logsFile = File(filesDir, "la-lune/logs.log")
            watchLogsAndEstablish(logsFile)
        }
        startNotificationTicker()
    }

    /**
     * Периодически обновляет уведомление — чтобы статистика
     * (Активных / Трафик) не застывала в одном значении.
     */
    private fun startNotificationTicker() {
        notificationTickerJob?.cancel()
        notificationTickerJob = scope.launch {
            while (isActive && isRunning) {
                delay(NOTIFICATION_TICK_MS)
                // Обновляем ongoing notification даже до поднятия TUN:
                // активные сессии и трафик читаются из логов независимо от TUN.
                updateNotification()
            }
        }
    }

    private suspend fun watchLogsAndEstablish(logsFile: File) = withContext(Dispatchers.IO) {
        var lastOffset = 0L
        var waited = 0L
        val timeoutMs = 90_000L

        Log.d(TAG, "watching ${logsFile.absolutePath}")
        while (isRunning && waited < timeoutMs && !tunEstablished) {
            if (logsFile.exists()) {
                try {
                    val content = logsFile.readText()
                    if (content.length > lastOffset) {
                        val newPart = content.substring(lastOffset.toInt())
                        lastOffset = content.length.toLong()

                        newPart.lines().forEach { line ->
                            if (line.isBlank()) return@forEach

                            coreManager.parseTunconf(line)?.let { (ip, dns) ->
                                detectedTunIP = ip
                                detectedDNS = dns
                            }

                            coreManager.parseStats(line)?.let { (active, traffic) ->
                                activeSessions = active
                                trafficMB = String.format("%.2f", traffic)
                                updateNotification()

                                if (active > 0) consecutiveActiveTicks++
                                else consecutiveActiveTicks = 0

                                if (active > 0 && consecutiveActiveTicks >= 2 &&
                                    !tunEstablished && !establishing
                                ) {
                                    establishing = true
                                    Log.i(TAG, "establishing TUN (active=$active)")
                                    withContext(Dispatchers.Main) { establishTun() }
                                    establishing = false
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "read log: ${e.message}")
                }
            }
            delay(500)
            waited += 500
        }
        if (!tunEstablished) Log.w(TAG, "timeout waiting for TUNCONF + Активных>0")
    }

    private fun readRoutingSettings(): JSONObject {
        return try {
            val file = File(filesDir, "la-lune/settings.json")
            if (file.exists()) JSONObject(file.readText()) else JSONObject()
        } catch (e: Exception) {
            Log.w(TAG, "Unable to read routing settings: ${e.message}")
            JSONObject()
        }
    }

    private fun parseIpPrefix(entry: String): Pair<InetAddress, Int> {
        val value = normalizeIpPrefix(entry)
        val separator = value.lastIndexOf('/')
        require(separator > 0 && separator < value.lastIndex) { "invalid IP/CIDR: $entry" }
        val address = InetAddress.getByName(value.substring(0, separator))
        val prefixLength = value.substring(separator + 1).toInt()
        val maxPrefixLength = if (address.address.size == 4) 32 else 128
        require(prefixLength in 0..maxPrefixLength) { "invalid prefix length: $entry" }
        return address to prefixLength
    }

    private fun normalizeIpPrefix(entry: String): String {
        val value = entry.trim()
        require(value.isNotEmpty()) { "empty IP" }
        if (value.contains('/')) return value
        return value + if (value.contains(':')) "/128" else "/32"
    }

    private fun establishTun() {
        if (tunEstablished) return
        Log.d(TAG, "establishTun")

        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        try {
            val tunIP = detectedTunIP ?: DEFAULT_TUN_IP
            val dnsList = (detectedDNS ?: "$DEFAULT_DNS_1,$DEFAULT_DNS_2")
                .split(",").map { it.trim() }.filter { it.isNotEmpty() }

            val routing = readRoutingSettings()
            val builder = Builder()
                .setSession("LaLune")
                .setMtu(MTU)
                .addAddress(tunIP, 32)

            val configuredIps = routing.optString("ipRoutingIps", "")
                .lines()
                .map { it.trim() }
                .filter { it.isNotEmpty() && !it.startsWith("#") }
                .distinct()
            val ipMode = routing.optString("ipRoutingMode", "blacklist")
            if (ipMode == "whitelist") {
                // White list: only explicitly listed destination networks enter the VPN.
                configuredIps.forEach { entry ->
                    try {
                        val (address, prefixLength) = parseIpPrefix(entry)
                        builder.addRoute(address, prefixLength)
                    } catch (e: Exception) {
                        Log.w(TAG, "Invalid whitelist IP/CIDR '$entry': ${e.message}")
                    }
                }
                if (configuredIps.isEmpty()) {
                    Log.w(TAG, "IP whitelist is empty: no destination IP routes will be added")
                }
            } else {
                builder.addRoute(InetAddress.getByName("0.0.0.0"), 0)
                configuredIps.forEach { entry ->
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            builder.excludeRoute(parseIpPrefix(entry).let { (address, prefixLength) -> IpPrefix(address, prefixLength) })
                        } else {
                            Log.w(TAG, "IP blacklist exclusions require Android 13+; cannot bypass '$entry' on this Android version")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Invalid blacklist IP/CIDR '$entry': ${e.message}")
                    }
                }
            }

            val appMode = routing.optString("androidAppRoutingMode", "blacklist")
            val appArray = routing.optJSONArray("androidVpnApps") ?: JSONArray()
            val selectedPackages = (0 until appArray.length())
                .mapNotNull { appArray.optString(it).takeIf { name -> name.isNotBlank() } }
                .distinct()
            if (appMode == "whitelist") {
                selectedPackages.forEach { packageName ->
                    try {
                        builder.addAllowedApplication(packageName)
                    } catch (e: Exception) {
                        Log.w(TAG, "Cannot allow app '$packageName': ${e.message}")
                    }
                }
            } else {
                selectedPackages.forEach { packageName ->
                    try {
                        builder.addDisallowedApplication(packageName)
                    } catch (e: Exception) {
                        Log.w(TAG, "Cannot bypass app '$packageName': ${e.message}")
                    }
                }
            }

            if (dnsList.isEmpty()) {
                builder.addDnsServer(DEFAULT_DNS_1)
                builder.addDnsServer(DEFAULT_DNS_2)
            } else {
                dnsList.forEach { builder.addDnsServer(it) }
            }

            if (routing.optString("androidAppRoutingMode", "blacklist") != "whitelist") {
                try {
                    builder.addDisallowedApplication(packageName)
                } catch (e: Exception) {
                    Log.w(TAG, "addDisallowedApplication failed: ${e.message}")
                }
            }

            builder.setBlocking(true)

            val iface = builder.establish() ?: run {
                Log.e(TAG, "establish() null — no VPN permission")
                return
            }

            vpnInterface = iface
            tunEstablished = true
            Log.d(TAG, "establish() ok, fd=${iface.fd}")

            scope.launch { setupSocketAndBridges(iface, tunIP) }
            notifyStatus(this, true)
            updateNotification()
        } catch (e: Exception) {
            Log.e(TAG, "establishTun: ${e.message}", e)
            tunEstablished = false
        }
    }

    private suspend fun setupSocketAndBridges(iface: ParcelFileDescriptor, tunIP: String) =
        withContext(Dispatchers.IO) {
            try {
                val socket = DatagramSocket()
                socket.connect(InetAddress.getByName("127.0.0.1"), CORE_PORT)
                udpSocket = socket

                Log.i(TAG, "TUN up: IP=$tunIP, UDP bridge to 127.0.0.1:$CORE_PORT")
                updateNotification()

                launch { tunToUdp(iface, socket) }
                launch { udpToTun(iface, socket) }
            } catch (e: Exception) {
                Log.e(TAG, "setupSocket: ${e.message}", e)
                tunEstablished = false
                try { iface.close() } catch (_: Exception) {}
                vpnInterface = null
                notifyStatus(this@LaLuneVpnService, false)
            }
        }

    private suspend fun tunToUdp(iface: ParcelFileDescriptor, socket: DatagramSocket) {
        val input = FileInputStream(iface.fileDescriptor)
        val buf = ByteArray(65535)
        while (isRunning && tunEstablished) {
            try {
                val n = input.read(buf)
                if (n > 0) socket.send(DatagramPacket(buf.copyOf(n), n))
            } catch (e: Exception) {
                Log.w(TAG, "tunToUdp: ${e.message}"); break
            }
        }
    }

    private suspend fun udpToTun(iface: ParcelFileDescriptor, socket: DatagramSocket) {
        val output = FileOutputStream(iface.fileDescriptor)
        val buf = ByteArray(65535)
        while (isRunning && tunEstablished) {
            try {
                val packet = DatagramPacket(buf, buf.size)
                socket.receive(packet)
                output.write(packet.data, 0, packet.length)
            } catch (e: Exception) {
                Log.w(TAG, "udpToTun: ${e.message}"); break
            }
        }
    }

    private fun stopFlow() {
        Log.d(TAG, "stopFlow")
        isRunning = false
        tunEstablished = false
        establishing = false

        notificationTickerJob?.cancel()
        notificationTickerJob = null

        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        activeSessions = 0
        consecutiveActiveTicks = 0
        trafficMB = "0.00"

        notifyStatus(this, false)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        stopFlow()
        scope.cancel()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "LaLune VPN", NotificationManager.IMPORTANCE_LOW
                )
                ch.setShowBadge(false)
                ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                mgr.createNotificationChannel(ch)
            }
        }

        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = Intent(this, LaLuneVpnService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val text = if (tunEstablished || activeSessions > 0 || trafficMB != "0.00") {
            "Активных: $activeSessions | Трафик: $trafficMB МБ"
        } else "Подключение..."

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("LaLune")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(openPending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Отключить",
                stopPending
            )
            .build()
    }

    private fun updateNotification() {
        try {
            val mgr = getSystemService(NotificationManager::class.java)
            mgr.notify(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            Log.w(TAG, "updateNotification: ${e.message}")
        }
    }

    private fun startForegroundCompat() {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, n,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }
}
