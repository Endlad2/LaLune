package com.lalune.app

import android.net.VpnService
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.*
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

class TunManager(private val vpnService: VpnService) {
    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var isRunning = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val corePort = 52230
    
    fun start(completion: (Boolean) -> Unit) {
        if (isRunning) {
            completion(false)
            return
        }
        
        try {
            // Создаём VPN интерфейс
            val builder = vpnService.Builder()
                .setSession("LaLune")
                .setMtu(1300)
                .addAddress("10.66.67.12", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("8.8.4.4")
                .setBlocking(true)
            
            vpnInterface = builder.establish()
            
            if (vpnInterface == null) {
                completion(false)
                return
            }
            
            isRunning = true
            
            // Подключаем UDP сокет к ядру
            udpSocket = DatagramSocket()
            udpSocket?.connect(InetAddress.getByName("127.0.0.1"), corePort)
            
            // Запускаем мосты
            scope.launch { tunToUdp() }
            scope.launch { udpToTun() }
            
            completion(true)
        } catch (e: Exception) {
            stop()
            completion(false)
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
    
    fun stop() {
        isRunning = false
        scope.coroutineContext.cancelChildren()
        
        udpSocket?.close()
        udpSocket = null
        
        vpnInterface?.close()
        vpnInterface = null
    }
    
    fun isActive(): Boolean = isRunning
}
