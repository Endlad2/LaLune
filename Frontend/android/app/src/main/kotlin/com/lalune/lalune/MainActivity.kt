// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// MainActivity: поднимает Backend, подключает Flutter UI поверх,
// следит за жизнью API (каждые 3 сек) и перезапускает при необходимости.
//
// ВАЖНО: Backend и LaLuneVpnService теперь в ТОМ ЖЕ package
// (com.lalune.lalune) — импорты не нужны.

package com.lalune.lalune

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "LaLune-MainActivity"
        private const val CHANNEL = "com.lalune/native"
        private const val REQ_VPN = 101
        private const val REQ_NOTIFICATIONS = 102

        private const val API_URL = "http://127.0.0.1:1062/ping"
        private const val WATCHDOG_INTERVAL_MS = 3000L
    }

    private var backend: Backend? = null
    private var methodChannel: MethodChannel? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var watchdogJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        backend = Backend(applicationContext).also {
            it.attachActivity(this)
            it.run()
        }
        Log.i(TAG, "Backend.run() called")

        requestNotificationPermissionIfNeeded()
        startApiWatchdog()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isBackendAlive" -> result.success(isBackendAlive())
                "restartBackend" -> {
                    restartBackend()
                    result.success(true)
                }
                "requestVpnPermission" -> {
                    requestVpnPermission()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIFICATIONS
            )
        }
    }

    private fun requestVpnPermission() {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            startActivityForResult(intent, REQ_VPN)
        } else {
            Log.i(TAG, "VPN permission already granted")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            if (resultCode == RESULT_OK) {
                backend?.onVpnPermissionGranted()
            } else {
                backend?.onVpnPermissionDenied()
            }
        }
    }

    private fun startApiWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = scope.launch {
            while (isActive) {
                delay(WATCHDOG_INTERVAL_MS)
                if (!isBackendAlive()) {
                    Log.w(TAG, "API not responding — restarting backend")
                    withContext(Dispatchers.Main) { restartBackend() }
                }
            }
        }
    }

    private fun isBackendAlive(): Boolean {
        return try {
            val conn = URL(API_URL).openConnection() as HttpURLConnection
            conn.connectTimeout = 1500
            conn.readTimeout = 1500
            conn.requestMethod = "GET"
            val code = conn.responseCode
            conn.disconnect()
            code in 200..299
        } catch (_: Exception) {
            false
        }
    }

    private fun restartBackend() {
        try {
            backend?.stop()
        } catch (_: Exception) {}
        backend = Backend(applicationContext).also {
            it.attachActivity(this)
            it.run()
        }
        Log.i(TAG, "Backend restarted")
    }

    override fun onDestroy() {
        watchdogJob?.cancel()
        scope.cancel()
        super.onDestroy()
    }
}
