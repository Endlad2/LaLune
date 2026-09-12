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

/**
 * VPN-сервис LaLune.
 *
 * Логика:
 *   1. При START запускает ядро (CoreManager.startCore) — оно слушает UDP на 127.0.0.1:52230.
 *   2. Параллельно читает лог ядра (files/la-lune/logs.txt) и ждёт строку
 *      "[СТАТИСТИКА] Активных: N | Траффик: M" с N > 0 — это значит, что ядро
 *      установило хотя бы одну TURN-сессию и реально может гонять трафик.
 *   3. Как только N > 0 впервые — поднимает VPN-интерфейс через Builder.establish()
 *      и запускает мост: TUN → UDP(127.0.0.1:52230) → ядро → TURN → интернет, и обратно.
 *   4. IP/DNS берутся из строки "TUNCONF:IP:DNS" в логе ядра, если она есть.
 *      Если ядро её не пишет — fallback 10.66.67.12 / 8.8.8.8,8.8.4.4.
 */
class LaLuneVpnService : VpnService() {

    companion object {
        private const val TAG = "LaLune-VPN"
        private const val CHANNEL_ID = "lalune_vpn"
        private const val NOTIFICATION_ID = 1
        private const val CORE_PORT = 52230
        private const val DEFAULT_TUN_IP = "10.66.67.12"
        private const val DEFAULT_DNS_1 = "8.8.8.8"
        private const val DEFAULT_DNS_2 = "8.8.4.4"
        private const val MTU = 1300

        private val STAT_RE = Pattern.compile(
            "\\[СТАТИСТИКА\\]\\s*Активных:\\s*(\\d+)\\s*\\|\\s*Траффик:\\s*(\\d+)"
        )
        private val TUNCONF_RE = Pattern.compile("TUNCONF:([\\d.]+):([\\d.,]+)")
        private val TUNCONF_ALT_RE = Pattern.compile(
            "Tunnel IP:\\s*([\\d.]+).*?DNS:\\s*([\\d.,]+)"
        )
    }

    @Volatile private var detectedTunIP: String? = null
    @Volatile private var detectedDNS: String? = null
    @Volatile private var activeSessions: Int = 0

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var isRunning = false
    private var tunEstablished = false

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
            "STOP" -> stopFlow()
        }
        return START_STICKY
    }

    private fun startFlow() {
        Log.d(TAG, "startFlow: запускаем ядро и ждём N > 0")

        scope.launch {
            val started = coreManager.startCore(
                peer = currentSetting("peer"),
                password = currentSetting("password"),
                hashes = currentSetting("vkHashes")
            )
            if (!started) {
                Log.e(TAG, "ядро не запустилось, стоп")
                withContext(Dispatchers.Main) { stopFlow() }
                return@launch
            }
            waitForActiveSessionsAndEstablish()
        }
    }

    /**
     * Читает files/la-lune/logs.txt в цикле, ищет [СТАТИСТИКА] с N > 0,
     * попутно выцепляет TUNCONF. Как только N > 0 впервые — establish().
     */
    private suspend fun waitForActiveSessionsAndEstablish() = withContext(Dispatchers.IO) {
        val logsFile = File(filesDir, "la-lune/logs.txt")
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
                                    Log.d(TAG, "TUNCONF: IP=${detectedTunIP} DNS=${detectedDNS}")
                                }
                            }
                            TUNCONF_ALT_RE.matcher(line).let { m ->
                                if (m.find()) {
                                    detectedTunIP = m.group(1)
                                    detectedDNS = m.group(2)
                                    Log.d(TAG, "TUNCONF(alt): IP=${detectedTunIP} DNS=${detectedDNS}")
                                }
                            }

                            STAT_RE.matcher(line).let { m ->
                                if (m.find()) {
                                    val n = m.group(1)?.toIntOrNull() ?: 0
                                    activeSessions = n
                                    Log.d(TAG, "[СТАТИСТИКА] Активных=$n")

                                    if (n > 0 && !tunEstablished) {
                                        Log.i(TAG, "N > 0 — поднимаем TUN")
                                        withContext(Dispatchers.Main) {
                                            establishTun()
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "чтение лога: ${e.message}")
                }
            }
            delay(500)
            waited += 500
        }

        if (!tunEstablished) {
            Log.w(TAG, "таймаут ожидания N > 0 (${timeoutMs}ms). TUN не поднят.")
        }
    }

    private fun establishTun() {
        if (tunEstablished) return

        try {
            val builder = Builder()
                .setSession("LaLune")
                .setMtu(MTU)
                .addAddress(detectedTunIP ?: DEFAULT_TUN_IP, 32)
                .addRoute("0.0.0.0", 0)

            val dnsList = (detectedDNS ?: "$DEFAULT_DNS_1,$DEFAULT_DNS_2")
                .split(",")
                .map { it.trim() }
                .filter { it.isNotEmpty() }

            if (dnsList.isEmpty()) {
                builder.addDnsServer(DEFAULT_DNS_1)
                builder.addDnsServer(DEFAULT_DNS_2)
            } else {
                dnsList.forEach { builder.addDnsServer(it) }
            }

            // Чтобы приложение не заворачивало в VPN само себя (иначе петля)
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                Log.w(TAG, "addDisallowedApplication: ${e.message}")
            }

            builder.setBlocking(true)

            val iface = builder.establish()
            if (iface == null) {
                Log.e(TAG, "establish() вернул null")
                return
            }

            vpnInterface = iface

            val socket = DatagramSocket()
            socket.connect(InetAddress.getByName("127.0.0.1"), CORE_PORT)
            udpSocket = socket

            tunEstablished = true
            Log.i(TAG, "TUN поднят: IP=${detectedTunIP ?: DEFAULT_TUN_IP}")

            scope.launch { tunToUdp(iface, socket) }
            scope.launch { udpToTun(iface, socket) }

        } catch (e: Exception) {
            Log.e(TAG, "establishTun: ${e.message}", e)
        }
    }

    private suspend fun tunToUdp(iface: ParcelFileDescriptor, socket: DatagramSocket) =
        withContext(Dispatchers.IO) {
            val input = FileInputStream(iface.fileDescriptor)
            val buffer = ByteArray(65535)

            while (isRunning && tunEstablished) {
                try {
                    val n = input.read(buffer)
                    if (n > 0) {
                        val packet = DatagramPacket(buffer.copyOf(n), n)
                        socket.send(packet)
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "tunToUdp: ${e.message}")
                    break
                }
            }
        }

    private suspend fun udpToTun(iface: ParcelFileDescriptor, socket: DatagramSocket) =
        withContext(Dispatchers.IO) {
            val output = FileOutputStream(iface.fileDescriptor)
            val buffer = ByteArray(65535)

            while (isRunning && tunEstablished) {
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    output.write(packet.data, 0, packet.length)
                } catch (e: Exception) {
                    Log.w(TAG, "udpToTun: ${e.message}")
                    break
                }
            }
        }

    private fun stopFlow() {
        Log.d(TAG, "stopFlow")
        isRunning = false

        scope.launch {
            try { coreManager.stopCore() } catch (e: Exception) {
                Log.w(TAG, "stopCore: ${e.message}")
            }
        }

        udpSocket?.close()
        udpSocket = null

        vpnInterface?.close()
        vpnInterface = null

        tunEstablished = false
        activeSessions = 0

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

    private fun startForegroundCompat() {
        val notification = createNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "LaLune VPN", NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("LaLune")
            .setContentText("VPN активен")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .build()
    }
}
