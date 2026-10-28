// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VpnService с TUN + UDP-мост к ядру CSQTT.
//
// package = com.lalune.lalune — тот же, что у MainActivity и Backend.
//
// Порядок подключения:
//   1. Ядро запускается Backend'ом до startForegroundService.
//   2. После первого "Активных: N>0" показываем «Проверка» и ждём ещё 3
//      положительных тика подряд.
//   3. Поднимаем TUN + UDP-мост, показываем «Проверка туннеля» и проверяем
//      telegram.org / youtube.com именно через Android VPN Network.
//   4. Если оба запроса не прошли — закрываем только TUN, перечитываем
//      TUN-параметры из logs.log и повторяем. Ядро при этом не останавливается.
//
// Уведомление: отдельный тикер каждые 2 сек обновляет notification,
// чтобы статистика (Активных / Трафик) не "застывала".

package com.lalune.lalune

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
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
        private const val REQUIRED_ACTIVE_TICKS = 4 // первый >0 + ещё 3 проверки
        private const val LOG_POLL_MS = 500L
        private const val TUN_RETRY_DELAY_MS = 1_000L
        private const val VPN_NETWORK_WAIT_MS = 3_000L
        private const val HTTP_TIMEOUT_MS = 6_000

        private val TUN_CHECK_URLS = listOf(
            "https://telegram.org/",
            "https://youtube.com/",
        )

        /** Периодичность обновления уведомления (2 сек). */
        private const val NOTIFICATION_TICK_MS = 2_000L

        const val ACTION_STATUS = "com.lalune.lalune.VPN_STATUS"
        const val EXTRA_CONNECTED = "connected"
        const val EXTRA_STATE = "state"
        const val EXTRA_MESSAGE = "message"

        fun notifyStatus(
            ctx: Context,
            connected: Boolean,
            state: String = if (connected) "connected" else "disconnected",
            message: String = if (connected) "Подключено" else "",
        ) {
            val i = Intent(ACTION_STATUS).apply {
                setPackage(ctx.packageName)
                putExtra(EXTRA_CONNECTED, connected)
                putExtra(EXTRA_STATE, state)
                putExtra(EXTRA_MESSAGE, message)
            }
            ctx.sendBroadcast(i)
        }
    }

    @Volatile private var detectedTunIP: String? = null
    @Volatile private var detectedDNS: String? = null
    @Volatile private var activeSessions: Int = 0
    @Volatile private var consecutiveActiveTicks: Int = 0
    @Volatile private var trafficMB: String = "0.00"
    @Volatile private var connectionState: String = "disconnected"
    @Volatile private var connectionMessage: String = ""
    @Volatile private var screenInteractive: Boolean = true
    @Volatile private var rescanLogsRequested: Boolean = false
    @Volatile private var fastTunRebuild: Boolean = false
    @Volatile private var hadTunnel: Boolean = false

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    @Volatile private var isRunning = false
    @Volatile private var tunEstablished = false
    @Volatile private var establishing = false
    @Volatile private var tunnelGeneration = 0L

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val tunnelMutex = Mutex()
    private lateinit var coreManager: CoreManager
    private var notificationTickerJob: Job? = null
    private var flowJob: Job? = null
    private val bridgeJobs = mutableListOf<Job>()

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenInteractive = false
                    Log.i(TAG, "screen off: closing TUN only; core stays alive")
                    scope.launch {
                        teardownTunnelOnly("screen off")
                        consecutiveActiveTicks = 0
                        detectedTunIP = null
                        detectedDNS = null
                        fastTunRebuild = hadTunnel
                        rescanLogsRequested = true
                        if (isRunning) publishState("connecting", false, "Подключение")
                    }
                }
                Intent.ACTION_SCREEN_ON -> {
                    screenInteractive = true
                    Log.i(TAG, "screen on: re-reading TUN params and reconnecting")
                    consecutiveActiveTicks = 0
                    detectedTunIP = null
                    detectedDNS = null
                    fastTunRebuild = hadTunnel
                    rescanLogsRequested = true
                    if (isRunning) publishState("connecting", false, "Подключение")
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        coreManager = CoreManager(this)
        screenInteractive = getSystemService(PowerManager::class.java)?.isInteractive ?: true
        registerScreenReceiver()
        startForegroundCompat()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START" -> if (!isRunning) {
                isRunning = true
                publishState("connecting", false, "Подключение")
                startFlow()
            }
            "STOP", ACTION_STOP -> stopFlow()
        }
        return START_STICKY
    }

    private fun registerScreenReceiver() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(screenReceiver, filter)
        }
    }

    private fun startFlow() {
        Log.d(TAG, "startFlow")
        flowJob?.cancel()
        flowJob = scope.launch {
            val logsFile = File(filesDir, "la-lune/logs.log")
            watchLogsAndManageTunnel(logsFile)
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
                updateNotification()
            }
        }
    }

    private suspend fun watchLogsAndManageTunnel(logsFile: File) = withContext(Dispatchers.IO) {
        var lastOffset = 0L
        Log.d(TAG, "watching ${logsFile.absolutePath}")

        while (isRunning) {
            if (!screenInteractive) {
                delay(LOG_POLL_MS)
                continue
            }

            if (rescanLogsRequested) {
                lastOffset = 0L
                consecutiveActiveTicks = 0
                detectedTunIP = null
                detectedDNS = null
                rescanLogsRequested = false
                Log.i(TAG, "re-reading logs for fresh TUN parameters")
            }

            if (logsFile.exists()) {
                try {
                    val content = logsFile.readText()
                    if (content.length.toLong() < lastOffset) lastOffset = 0L
                    if (content.length.toLong() > lastOffset) {
                        val newPart = content.substring(lastOffset.toInt())
                        lastOffset = content.length.toLong()
                        for (line in newPart.lines()) {
                            if (line.isBlank()) continue

                            coreManager.parseTunconf(line)?.let { (ip, dns) ->
                                detectedTunIP = ip
                                detectedDNS = dns
                            }

                            coreManager.parseStats(line)?.let { (active, traffic) ->
                                activeSessions = active
                                trafficMB = String.format("%.2f", traffic)
                                updateNotification()

                                if (!tunEstablished && !establishing && !fastTunRebuild) {
                                    if (active > 0) {
                                        consecutiveActiveTicks++
                                        if (consecutiveActiveTicks == 1) {
                                            publishState("checking", false, "Проверка")
                                        }
                                    } else {
                                        consecutiveActiveTicks = 0
                                        publishState("connecting", false, "Подключение")
                                    }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "read log: ${e.message}")
                }
            }

            val readyForTun = !tunEstablished && !establishing &&
                detectedTunIP != null && detectedDNS != null &&
                (fastTunRebuild || consecutiveActiveTicks >= REQUIRED_ACTIVE_TICKS)

            if (readyForTun) {
                establishing = true
                val established = establishTun()
                establishing = false

                if (established && isRunning && screenInteractive) {
                    publishState("checking_tunnel", false, "Проверка туннеля")
                    val internetOk = verifyTunnelConnectivity()
                    if (internetOk && isRunning && screenInteractive && tunEstablished) {
                        publishState("connected", true, "Подключено")
                        Log.i(TAG, "tunnel connectivity verified")
                    } else if (isRunning) {
                        Log.w(TAG, "tunnel check failed; rebuilding TUN without stopping core")
                        teardownTunnelOnly("connectivity check failed")
                        consecutiveActiveTicks = 0
                        detectedTunIP = null
                        detectedDNS = null
                        fastTunRebuild = true
                        rescanLogsRequested = true
                        publishState("checking_tunnel", false, "Проверка туннеля")
                        delay(TUN_RETRY_DELAY_MS)
                    }
                } else if (isRunning) {
                    consecutiveActiveTicks = 0
                    rescanLogsRequested = true
                    delay(TUN_RETRY_DELAY_MS)
                }
            }

            delay(LOG_POLL_MS)
        }
    }

    private fun publishState(state: String, connected: Boolean, message: String) {
        val changed = state != connectionState || message != connectionMessage
        connectionState = state
        connectionMessage = message
        if (changed || connected) {
            notifyStatus(this, connected, state, message)
            updateNotification()
        }
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

    private suspend fun establishTun(): Boolean = tunnelMutex.withLock {
        if (tunEstablished || !isRunning || !screenInteractive) return@withLock false
        Log.d(TAG, "establishTun")

        teardownTunnelOnlyLocked("before establish")
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

            val iface = withContext(Dispatchers.Main) { builder.establish() } ?: run {
                Log.e(TAG, "establish() null — no VPN permission")
                return@withLock false
            }

            val socket = try {
                DatagramSocket().also { bridge ->
                    // UDP-мост к ядру обязан идти вне VPN, иначе получим рекурсию.
                    if (!protect(bridge)) Log.w(TAG, "protect(UDP bridge) returned false")
                    bridge.connect(InetAddress.getByName("127.0.0.1"), CORE_PORT)
                }
            } catch (e: Exception) {
                try { iface.close() } catch (_: Exception) {}
                Log.e(TAG, "setupSocket: ${e.message}", e)
                return@withLock false
            }

            tunnelGeneration++
            val generation = tunnelGeneration
            vpnInterface = iface
            udpSocket = socket
            tunEstablished = true
            hadTunnel = true
            fastTunRebuild = false
            Log.i(TAG, "TUN up: IP=$tunIP, UDP bridge to 127.0.0.1:$CORE_PORT")

            bridgeJobs.forEach { it.cancel() }
            bridgeJobs.clear()
            bridgeJobs += scope.launch { tunToUdp(iface, socket, generation) }
            bridgeJobs += scope.launch { udpToTun(iface, socket, generation) }
            updateNotification()
            true
        } catch (e: Exception) {
            Log.e(TAG, "establishTun: ${e.message}", e)
            teardownTunnelOnlyLocked("establish failed")
            false
        }
    }

    private suspend fun verifyTunnelConnectivity(): Boolean = withContext(Dispatchers.IO) {
        val network = waitForVpnNetwork() ?: run {
            Log.w(TAG, "VPN Network not visible for tunnel check")
            return@withContext false
        }

        for (url in TUN_CHECK_URLS) {
            if (!isRunning || !screenInteractive || !tunEstablished) return@withContext false
            if (probeUrlThroughNetwork(network, url)) {
                Log.i(TAG, "tunnel check OK: $url")
                return@withContext true
            }
        }
        false
    }

    private suspend fun waitForVpnNetwork(): Network? {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return null
        var waited = 0L
        while (isRunning && screenInteractive && tunEstablished && waited <= VPN_NETWORK_WAIT_MS) {
            val network = cm.allNetworks.firstOrNull { candidate ->
                cm.getNetworkCapabilities(candidate)
                    ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            }
            if (network != null) return network
            delay(100L)
            waited += 100L
        }
        return null
    }

    private fun probeUrlThroughNetwork(network: Network, url: String): Boolean {
        var conn: HttpURLConnection? = null
        return try {
            conn = network.openConnection(URL(url)) as HttpURLConnection
            conn.instanceFollowRedirects = true
            conn.connectTimeout = HTTP_TIMEOUT_MS
            conn.readTimeout = HTTP_TIMEOUT_MS
            conn.requestMethod = "GET"
            conn.setRequestProperty("User-Agent", "LaLune-TunnelCheck/1.0")
            conn.setRequestProperty("Range", "bytes=0-0")
            val code = conn.responseCode
            code in 200..399
        } catch (e: Exception) {
            Log.w(TAG, "tunnel check failed for $url: ${e.message}")
            false
        } finally {
            try { conn?.inputStream?.close() } catch (_: Exception) {}
            try { conn?.errorStream?.close() } catch (_: Exception) {}
            conn?.disconnect()
        }
    }

    private suspend fun tunToUdp(
        iface: ParcelFileDescriptor,
        socket: DatagramSocket,
        generation: Long,
    ) {
        val input = FileInputStream(iface.fileDescriptor)
        val buf = ByteArray(65535)
        while (isRunning && tunEstablished && generation == tunnelGeneration) {
            try {
                val n = input.read(buf)
                if (n > 0) socket.send(DatagramPacket(buf.copyOf(n), n))
            } catch (e: Exception) {
                if (isRunning && generation == tunnelGeneration) Log.w(TAG, "tunToUdp: ${e.message}")
                break
            }
        }
    }

    private suspend fun udpToTun(
        iface: ParcelFileDescriptor,
        socket: DatagramSocket,
        generation: Long,
    ) {
        val output = FileOutputStream(iface.fileDescriptor)
        val buf = ByteArray(65535)
        while (isRunning && tunEstablished && generation == tunnelGeneration) {
            try {
                val packet = DatagramPacket(buf, buf.size)
                socket.receive(packet)
                output.write(packet.data, 0, packet.length)
            } catch (e: Exception) {
                if (isRunning && generation == tunnelGeneration) Log.w(TAG, "udpToTun: ${e.message}")
                break
            }
        }
    }

    private suspend fun teardownTunnelOnly(reason: String) = tunnelMutex.withLock {
        teardownTunnelOnlyLocked(reason)
    }

    private fun teardownTunnelOnlyLocked(reason: String) {
        if (tunEstablished || vpnInterface != null || udpSocket != null) {
            Log.i(TAG, "closing TUN only ($reason); core remains running")
        }
        tunnelGeneration++
        tunEstablished = false
        bridgeJobs.forEach { it.cancel() }
        bridgeJobs.clear()
        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null
    }

    private fun stopFlow() {
        Log.d(TAG, "stopFlow")
        isRunning = false
        establishing = false
        flowJob?.cancel()
        flowJob = null
        notificationTickerJob?.cancel()
        notificationTickerJob = null

        tunnelGeneration++
        tunEstablished = false
        bridgeJobs.forEach { it.cancel() }
        bridgeJobs.clear()
        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        activeSessions = 0
        consecutiveActiveTicks = 0
        trafficMB = "0.00"
        detectedTunIP = null
        detectedDNS = null
        fastTunRebuild = false
        hadTunnel = false
        connectionState = "disconnected"
        connectionMessage = ""
        notifyStatus(this, false, "disconnected", "")
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        try { unregisterReceiver(screenReceiver) } catch (_: Exception) {}
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

        val text = when (connectionState) {
            "checking" -> "Проверка"
            "checking_tunnel" -> "Проверка туннеля"
            "connected" -> "Активных: $activeSessions | Трафик: $trafficMB МБ"
            else -> "Подключение"
        }

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
