// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SOCKS5-сервер для раздачи VPN на Android.
//
// package = com.lalune.lalune — тот же, что у MainActivity и Backend.
//
// Слушает 0.0.0.0:1080. Все входящие CONNECT-запросы проксирует
// через TUN (default route уже указывает на VPN).
//
// Логирует "[PROXY] Listening socks5 on <real-ip>:1080" в общий лог
// бэкенда — фронт показывает его во вкладке Логи.

package com.lalune.lalune

import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.Collections
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.concurrent.thread

class Socks5Server(
    private val port: Int,
    private val log: (String) -> Unit,
) {
    companion object {
        private const val TAG = "LaLune-Socks5"
    }

    @Volatile private var running = false
    private var serverSocket: java.net.ServerSocket? = null
    private val executor: ExecutorService = Executors.newCachedThreadPool()

    fun start() {
        running = true
        thread(name = "socks5-accept", isDaemon = true) {
            try {
                val ss = java.net.ServerSocket(port, 50, java.net.InetAddress.getByName("0.0.0.0"))
                serverSocket = ss
                val realIp = localIpAddress() ?: "0.0.0.0"
                log("[PROXY] Listening socks5 on $realIp:$port")
                while (running) {
                    try {
                        val client = ss.accept()
                        executor.execute { handleClient(client) }
                    } catch (e: Exception) {
                        if (running) Log.e(TAG, "accept: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                log("[PROXY] failed to bind :$port — ${e.message}")
                Log.e(TAG, "bind failed", e)
            }
        }
    }

    fun stop() {
        running = false
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        executor.shutdownNow()
        log("[PROXY] stopped")
    }

    // ============================================================
    //  SOCKS5
    // ============================================================

    private fun handleClient(client: Socket) {
        client.use { c ->
            try {
                c.soTimeout = 30_000
                val input = c.getInputStream()
                val output = c.getOutputStream()

                // --- Greeting ---
                val ver = input.read()
                if (ver != 0x05) return
                val nMethods = input.read()
                if (nMethods <= 0) return
                val methods = ByteArray(nMethods)
                readFully(input, methods)

                // Отвечаем "no auth"
                output.write(byteArrayOf(0x05, 0x00))
                output.flush()

                // --- Request ---
                val hdr = ByteArray(4)
                readFully(input, hdr)
                if (hdr[0] != 0x05.toByte()) return
                if (hdr[1] != 0x01.toByte()) {
                    // Только CONNECT
                    output.write(byteArrayOf(0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
                    output.flush()
                    return
                }

                val host: String
                when (hdr[3].toInt()) {
                    0x01 -> {
                        val addr = ByteArray(4); readFully(input, addr)
                        host = "${addr[0].toInt() and 0xFF}.${addr[1].toInt() and 0xFF}." +
                                "${addr[2].toInt() and 0xFF}.${addr[3].toInt() and 0xFF}"
                    }
                    0x03 -> {
                        val len = input.read()
                        if (len <= 0) return
                        val domain = ByteArray(len); readFully(input, domain)
                        host = String(domain, Charsets.UTF_8)
                    }
                    0x04 -> {
                        val addr = ByteArray(16); readFully(input, addr)
                        // Простейшее разворачивание IPv6
                        val sb = StringBuilder()
                        for (i in 0 until 8) {
                            if (i > 0) sb.append(':')
                            sb.append(String.format("%x", ((addr[i*2].toInt() and 0xFF) shl 8) or (addr[i*2+1].toInt() and 0xFF)))
                        }
                        host = sb.toString()
                    }
                    else -> return
                }
                val portBytes = ByteArray(2); readFully(input, portBytes)
                val targetPort = ((portBytes[0].toInt() and 0xFF) shl 8) or (portBytes[1].toInt() and 0xFF)

                // --- Connect ---
                val remote = Socket()
                try {
                    remote.connect(InetSocketAddress(host, targetPort), 15_000)
                } catch (e: Exception) {
                    output.write(byteArrayOf(0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
                    output.flush()
                    return
                }

                // Успех
                output.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
                output.flush()

                // --- Pump ---
                val t1 = thread(isDaemon = true) { pump(c.getInputStream(), remote.getOutputStream()) }
                val t2 = thread(isDaemon = true) { pump(remote.getInputStream(), c.getOutputStream()) }
                t1.join()
                t2.join()
            } catch (_: Exception) {
            } finally {
                try { c.close() } catch (_: Exception) {}
            }
        }
    }

    private fun pump(input: InputStream, output: OutputStream) {
        try {
            val buf = ByteArray(8192)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (_: Exception) {
        } finally {
            try { output.close() } catch (_: Exception) {}
            try { input.close() } catch (_: Exception) {}
        }
    }

    private fun readFully(input: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n <= 0) throw java.io.EOFException()
            off += n
        }
    }

    // ============================================================
    //  Реальный IP устройства
    // ============================================================

    private fun localIpAddress(): String? {
        try {
            for (iface in Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (iface.isLoopback || !iface.isUp) continue
                for (addr in Collections.list(iface.inetAddresses)) {
                    if (!addr.isLoopbackAddress && addr is java.net.Inet4Address) {
                        return addr.hostAddress
                    }
                }
            }
        } catch (_: Exception) {}
        return null
    }
}
