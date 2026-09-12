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
 * Последовательность:
 *  1. START — запускаем ядро через CoreManager. Ядро пишет в files/la-lune/logs.log.
 *  2. Читаем logs.log, ждём "[СТАТИСТИКА] Активных: N" с N > 0.
 *  3. Парсим "Tunnel IP: ... | DNS: ...".
 *  4. establish(): создаём TUN, БЕЗ трафика самого приложения (addDisallowedApplication).
 *  5. Запускаем UDP-мост TUN↔127.0.0.1:52230 (в IO-корутинах, не на main).
 *
 * Трафик самого приложения LaLune ИСКЛЮЧЁН из VPN — иначе будет петля:
 * приложение → tun0 → UDP 52230 → tun0 → ...
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

        // "[СТАТИСТИКА] Активных: N | Трафик: M"
        // Ядро пишет "Трафик" с одной "ф". Регекс допускает оба варианта.
        private val STAT_RE = Pattern.compile(
            "\\[СТАТИСТИКА\\]\\s*Активных:\\s*(\\d+)\\s*\\|\\s*Трафи[кф]+:\\s*([\\d.]+)"
        )
        // TUNCONF:10.66.67.12:8.8.8.8
        private val TUNCONF_RE = Pattern.compile("TUNCONF:([\\d.]+):([\\d.,]+)")
        // Tunnel IP: 10.66.67.11/32 | DNS: 77.88.8.8,77.88.8.1
        private val TUNCONF_ALT_RE = Pattern.compile(
            "Tunnel IP:\\s*([\\d.]+)(?:/\\d+)?\\s*\\|\\s*DNS:\\s*([\\d.,]+)"
        )
    }

    @Volatile private var detectedTunIP: String? = null
    @Volatile private var detectedDNS: String? = null
    @Volatile private var activeSessions: Int = 0

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
            "STOP" -> stopFlow()
        }
        return START_STICKY
    }

    private fun startFlow() {
        Log.d(TAG, "startFlow")
        scope.launch {
            val started = coreManager.startCore(
                peer = currentSetting("peer"),
                password = currentSetting("password"),
                hashes = currentSetting("vkHashes")
            )
            if (!started) {
                Log.e(TAG, "core start failed")
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
                                    Log.d(TAG, "TunnelIP: IP=${detectedTunIP} DNS=${detectedDNS}")
                                }
                            }

                            STAT_RE.matcher(line).let { m ->
                                if (m.find()) {
                                    val n = m.group(1)?.toIntOrNull() ?: 0
                                    activeSessions = n

                                    if (n > 0 && !tunEstablished && !establishing) {
                                        establishing = true
                                        Log.i(TAG, "N=$n, establishing TUN")
                                        withContext(Dispatchers.Main) {
                                            establishTun()
                                        }
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

        if (!tunEstablished) {
            Log.w(TAG, "timeout waiting for N > 0")
        }
    }

    /**
     * Только Builder.establish() на main-потоке.
     * Всё остальное — в IO-корутине (DatagramSocket.connect() на main запрещён).
     */
    private fun establishTun() {
        if (tunEstablished) return
        Log.d(TAG, "establishTun start")

        // Закрываем висящий интерфейс от прошлых попыток, если был.
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        try {
            val tunIP = detectedTunIP ?: DEFAULT_TUN_IP
            val dnsList = (detectedDNS ?: "$DEFAULT_DNS_1,$DEFAULT_DNS_2")
                .split(",")
                .map { it.trim() }
                .filter { it.isNotEmpty() }

            Log.d(TAG, "TUN params: IP=$tunIP DNS=$dnsList")

            val builder = Builder()
                .setSession("LaLune")
                .setMtu(MTU)
                .addAddress(tunIP, 32)
                // route для всех IPv4
                .addRoute("0.0.0.0", 0)

            // DNS от ядра
            if (dnsList.isEmpty()) {
                builder.addDnsServer(DEFAULT_DNS_1)
                builder.addDnsServer(DEFAULT_DNS_2)
            } else {
                dnsList.forEach { builder.addDnsServer(it) }
            }

            // КРИТИЧНО: исключаем трафик нашего приложения из VPN.
            // Иначе получим петлю: приложение → tun0 → UDP 52230 → tun0 → ...
            try {
                builder.addDisallowedApplication(packageName)
                Log.i(TAG, "addDisallowedApplication OK: $packageName")
            } catch (e: Exception) {
                Log.w(TAG, "addDisallowedApplication failed: ${e.message}")
            }

            builder.setBlocking(true)

            val iface = builder.establish()
            if (iface == null) {
                Log.e(TAG, "establish() null — no VPN permission?")
                return
            }

            vpnInterface = iface
            // Флаг сразу, чтобы парсер не вызвал establishTun повторно
            tunEstablished = true
            Log.d(TAG, "establish() ok, fd=${iface.fd}")

            // Всё, что связано с сокетом и мостами — в IO
            scope.launch { setupSocketAndBridges(iface, tunIP) }

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

                launch { tunToUdp(iface, socket) }
                launch { udpToTun(iface, socket) }
            } catch (e: Exception) {
                Log.e(TAG, "setupSocket: ${e.message}", e)
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
                if (n > 0) {
                    socket.send(DatagramPacket(buffer.copyOf(n), n))
                }
            } catch (e: Exception) {
                Log.w(TAG, "tunToUdp: ${e.message}")
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
                Log.w(TAG, "udpToTun: ${e.message}")
                break
            }
        }
    }

    private fun stopFlow() {
        Log.d(TAG, "stopFlow")
        isRunning = false
        tunEstablished = false
        establishing = false

        scope.launch {
            try { coreManager.stopCore() } catch (e: Exception) {
                Log.w(TAG, "stopCore: ${e.message}")
            }
        }

        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null

        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

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
