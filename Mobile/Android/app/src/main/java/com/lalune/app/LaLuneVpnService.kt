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
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.*
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

class LaLuneVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var isRunning = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val corePort = 52230

    override fun onCreate() {
        super.onCreate()
        startForegroundCompat()
    }

    private fun startForegroundCompat() {
        val notification = createNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // На Android 10+ нужно указывать тип сервиса.
            // Для API 34+ без FOREGROUND_SERVICE_SPECIAL_USE и явного типа
            // система бросает SecurityException.
            ServiceCompat.startForeground(
                this,
                1,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(1, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START" -> startVpn()
            "STOP" -> stopVpn()
        }
        return START_STICKY
    }

    private fun startVpn() {
        if (isRunning) return
        isRunning = true

        try {
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

            udpSocket = DatagramSocket()
            udpSocket?.connect(InetAddress.getByName("127.0.0.1"), corePort)

            scope.launch { tunToUdp() }
            scope.launch { udpToTun() }

        } catch (e: Exception) {
            stopVpn()
        }
    }

    private suspend fun tunToUdp() = withContext(Dispatchers.IO) {
        val vpnFd = vpnInterface ?: return@withContext
        val input = FileInputStream(vpnFd.fileDescriptor)
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

    private suspend fun udpToTun() = withContext(Dispatchers.IO) {
        val vpnFd = vpnInterface ?: return@withContext
        val output = FileOutputStream(vpnFd.fileDescriptor)
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

    private fun stopVpn() {
        isRunning = false
        scope.coroutineContext.cancelChildren()

        udpSocket?.close()
        udpSocket = null

        vpnInterface?.close()
        vpnInterface = null

        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
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
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("LaLune")
            .setContentText("VPN активен")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .build()
    }
}
