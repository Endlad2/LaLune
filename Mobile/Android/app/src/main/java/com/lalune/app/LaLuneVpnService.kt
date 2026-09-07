package com.lalune.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

class LaLuneVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null
    private var coreProcess: Process? = null
    private var udpSocket: DatagramSocket? = null
    private var isRunning = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val corePort = 52230

    override fun onCreate() {
        super.onCreate()
        startForeground(1, createNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "CONNECT" -> startVpn()
            "DISCONNECT" -> stopVpn()
        }
        return START_STICKY
    }

    private fun startVpn() {
        if (isRunning) return
        isRunning = true

        val prefs = getSharedPreferences("lalune", MODE_PRIVATE)
        val peer = prefs.getString("peer", "") ?: ""
        val password = prefs.getString("password", "") ?: ""
        val hashes = prefs.getString("hashes", "") ?: ""
        val corePath = prefs.getString("corePath", "") ?: ""
        val coreDir = prefs.getString("coreDir", "") ?: ""

        // Создаём VPN интерфейс
        val builder = Builder()
            .setSession("LaLune")
            .setMtu(1300)
            .addAddress("10.66.67.12", 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .addDnsServer("8.8.4.4")
            .setBlocking(true)

        vpnInterface = builder.establish()

        if (vpnInterface == null) {
            stopVpn()
            return
        }

        // Запускаем ядро
        scope.launch {
            try {
                val processBuilder = ProcessBuilder(
                    corePath,
                    "--peer", peer,
                    "--password", password,
                    "--vk", hashes,
                    "--listen", "127.0.0.1:$corePort",
                    "-n", "9"
                )
                processBuilder.directory(File(coreDir))
                processBuilder.redirectErrorStream(true)
                coreProcess = processBuilder.start()

                // Ждём запуска ядра
                delay(2000)

                // Подключаем UDP мост
                udpSocket = DatagramSocket()
                udpSocket?.connect(InetAddress.getByName("127.0.0.1"), corePort)

                // TUN -> UDP
                launch { tunToUdp() }
                // UDP -> TUN
                launch { udpToTun() }

            } catch (e: Exception) {
                stopVpn()
            }
        }
    }

    private suspend fun tunToUdp() {
        val vpnFd = vpnInterface ?: return
        val input = FileInputStream(vpnFd.fileDescriptor)

        withContext(Dispatchers.IO) {
            val buffer = ByteArray(65535)
            while (isRunning) {
                try {
                    val n = input.read(buffer)
                    if (n > 0) {
                        val packet = DatagramPacket(buffer.copyOf(n), n)
                        udpSocket?.send(packet)
                    }
                } catch (e: Exception) {
                    break
                }
            }
        }
    }

    private suspend fun udpToTun() {
        val vpnFd = vpnInterface ?: return
        val output = FileOutputStream(vpnFd.fileDescriptor)

        withContext(Dispatchers.IO) {
            val buffer = ByteArray(65535)
            while (isRunning) {
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    udpSocket?.receive(packet)
                    output.write(packet.data, 0, packet.length)
                } catch (e: Exception) {
                    break
                }
            }
        }
    }

    private fun stopVpn() {
        isRunning = false
        scope.coroutineContext.cancelChildren()

        udpSocket?.close()
        udpSocket = null

        coreProcess?.destroy()
        coreProcess = null

        vpnInterface?.close()
        vpnInterface = null

        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    private fun createNotification(): Notification {
        val channelId = "lalune_vpn"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "LaLune VPN",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)

        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("LaLune")
            .setContentText("VPN активен")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .build()
    }
}
