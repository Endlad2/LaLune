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

package com.lalune.lalune

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
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

    private fun establishTun() {
        if (tunEstablished) return
        Log.d(TAG, "establishTun")

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
            } catch (e: Exception) {
                Log.w(TAG, "addDisallowedApplication failed: ${e.message}")
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

        val text = if (tunEstablished) {
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
