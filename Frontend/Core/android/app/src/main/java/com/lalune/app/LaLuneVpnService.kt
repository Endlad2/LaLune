// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.lalune.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.*
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.regex.Pattern

class LaLuneVpnService : VpnService() {

    companion object {
        private const val TAG = "LaLune-VPN"
        private const val CHANNEL_ID = "lalune_vpn"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.lalune.app.STOP_FROM_NOTIFICATION"
        private const val CORE_PORT = 52230
        private const val DEFAULT_TUN_IP = "10.66.67.12"
        private const val DEFAULT_DNS_1 = "8.8.8.8"
        private const val DEFAULT_DNS_2 = "8.8.4.4"
        private const val MTU = 1300

        private val STAT_RE = Pattern.compile(
            "\\[СТАТИСТИКА\\]\\s*Активных:\\s*(\\d+)\\s*\\|\\s*Трафи[кф]+:\\s*([\\d.]+)"
        )
        private val TUNCONF_RE = Pattern.compile("TUNCONF:([\\d.]+):([\\d.,]+)")
        private val TUNCONF_ALT_RE = Pattern.compile(
            "Tunnel IP:\\s*([\\d.]+)(?:/\\d+)?\\s*\\|\\s*DNS:\\s*([\\d.,]+)"
        )
    }

    @Volatile private var detectedTunIP: String? = null
    @Volatile private var detectedDNS: String? = null
    @Volatile private var activeSessions: Int = 0
    @Volatile private var trafficMB: String = "0.00"

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var isRunning = false
    @Volatile private var tunEstablished = false
    @Volatile private var establishing = false

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var coreManager: CoreManager

    override fun onCreate() {
        super.onCreate()
        coreManager = CoreManager(this)
        startForegroundCompat()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START" -> {
                if (!isRunning) {
                    isRunning = true
                    startFlow()
                }
            }
            "STOP", ACTION_STOP -> stopFlow()
        }
        return START_STICKY
    }

    private fun startFlow() {
        scope.launch {
            val started = coreManager.startCore(
                peer = currentSetting("peer"),
                password = currentSetting("password"),
                hashes = currentSetting("vkHashes")
            )
            if (!started) {
                withContext(Dispatchers.Main) { stopFlow() }
                return@launch
            }
            waitForActiveSessionsAndEstablish()
        }
    }

    private suspend fun waitForActiveSessionsAndEstablish() = withContext(Dispatchers.IO) {
        val logsFile = File(filesDir, "la-lune/logs.log")
        var lastOffset = 0L
        var waited = 0L
        val timeoutMs = 90_000L

        while (isRunning && waited < timeoutMs && !tunEstablished) {
            if (logsFile.exists()) {
                try {
                    val content = logsFile.readText()
                    if (content.length > lastOffset) {
                        val newPart = content.substring(lastOffset.toInt())
                        lastOffset = content.length.toLong()

                        newPart.lines().forEach { line ->
                            if (line.isBlank()) return@forEach

                            TUNCONF_RE.matcher(line).let { m ->
                                if (m.find()) {
                                    detectedTunIP = m.group(1)
                                    detectedDNS = m.group(2)
                                }
                            }
                            TUNCONF_ALT_RE.matcher(line).let { m ->
                                if (m.find()) {
                                    detectedTunIP = m.group(1)
                                    detectedDNS = m.group(2)
                                }
                            }

                            STAT_RE.matcher(line).let { m ->
                                if (m.find()) {
                                    val n = m.group(1)?.toIntOrNull() ?: 0
                                    activeSessions = n
                                    m.group(2)?.let { trafficMB = it }
                                    updateNotification()

                                    if (n > 0 && !tunEstablished && !establishing) {
                                        establishing = true
                                        withContext(Dispatchers.Main) { establishTun() }
                                        establishing = false
                                    }
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
    }

    private fun establishTun() {
        if (tunEstablished) return

        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        try {
            val tunIP = detectedTunIP ?: DEFAULT_TUN_IP
            val dnsList = (detectedDNS ?: "$DEFAULT_DNS_1,$DEFAULT_DNS_2")
                .split(",").map { it.trim() }.filter { it.isNotEmpty() }

            val builder = Builder()
                .setSession("LaLune")
                .setMtu(MTU)
                .addAddress(tunIP, 32)
                .addRoute("0.0.0.0", 0)

            if (dnsList.isEmpty()) {
                builder.addDnsServer(DEFAULT_DNS_1)
                builder.addDnsServer(DEFAULT_DNS_2)
            } else {
                dnsList.forEach { builder.addDnsServer(it) }
            }

            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {}

            builder.setBlocking(true)

            val iface = builder.establish() ?: return
            vpnInterface = iface
            tunEstablished = true

            scope.launch { setupSocketAndBridges(iface, tunIP) }
        } catch (e: Exception) {
            tunEstablished = false
        }
    }

    private suspend fun setupSocketAndBridges(iface: ParcelFileDescriptor, tunIP: String) =
        withContext(Dispatchers.IO) {
            try {
                val socket = DatagramSocket()
                socket.connect(InetAddress.getByName("127.0.0.1"), CORE_PORT)
                udpSocket = socket
                updateNotification()

                launch { tunToUdp(iface, socket) }
                launch { udpToTun(iface, socket) }
            } catch (e: Exception) {
                tunEstablished = false
                try { iface.close() } catch (_: Exception) {}
                vpnInterface = null
            }
        }

    private suspend fun tunToUdp(iface: ParcelFileDescriptor, socket: DatagramSocket) {
        val input = FileInputStream(iface.fileDescriptor)
        val buffer = ByteArray(65535)

        while (isRunning && tunEstablished) {
            try {
                val n = input.read(buffer)
                if (n > 0) socket.send(DatagramPacket(buffer.copyOf(n), n))
            } catch (e: Exception) {
                break
            }
        }
    }

    private suspend fun udpToTun(iface: ParcelFileDescriptor, socket: DatagramSocket) {
        val output = FileOutputStream(iface.fileDescriptor)
        val buffer = ByteArray(65535)

        while (isRunning && tunEstablished) {
            try {
                val packet = DatagramPacket(buffer, buffer.size)
                socket.receive(packet)
                output.write(packet.data, 0, packet.length)
            } catch (e: Exception) {
                break
            }
        }
    }

    private fun stopFlow() {
        isRunning = false
        tunEstablished = false
        establishing = false

        scope.launch {
            try { coreManager.stopCore() } catch (_: Exception) {}
        }

        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        activeSessions = 0
        trafficMB = "0.00"

        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        stopFlow()
        scope.cancel()
        super.onDestroy()
    }

    private fun currentSetting(key: String): String {
        val f = File(filesDir, "la-lune/settings.json")
        if (!f.exists()) return ""
        return try {
            org.json.JSONObject(f.readText()).optString(key, "")
        } catch (e: Exception) { "" }
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID, "LaLune VPN", NotificationManager.IMPORTANCE_LOW
                )
                channel.setShowBadge(false)
                mgr.createNotificationChannel(channel)
            }
        }

        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
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

        val text = if (tunEstablished) {
            "Активных: $activeSessions | Трафик: $trafficMB МБ"
        } else {
            "Подключение..."
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
        } catch (_: Exception) {}
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}
