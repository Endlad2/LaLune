package com.example.lalune_core

import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "lalune/api"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                // Заглушка: реальная реализация нативных методов
                // (configs / settings / logs / VK / deploy / TUN) добавляется
                // в класс LaLuneTokenFetcherAndroid и другие хелперы.
                when (call.method) {
                    "GetConfigsJson" -> result.success("[]")
                    "GetSettingsJson" -> result.success("{}")
                    "GetLogsJson" -> result.success("[]")
                    "GetStatusJson" -> result.success("{\"connected\":false}")
                    "GetVKTokenState" -> result.success(
                        "{\"hasToken\":false,\"fetcherOk\":false,\"fetching\":false,\"message\":\"\",\"progress\":0}"
                    )
                    "CheckCoreUpdate" -> result.success("{\"update\":false,\"version\":\"\"}")
                    "CheckLaLuneUpdate" -> result.success("{\"update\":false,\"version\":\"\"}")
                    "GetDeviceId" -> result.success("")
                    "IsCoreDownloading" -> result.success(false)
                    "IsDeploying" -> result.success(false)
                    "DeployLog" -> result.success("")
                    else -> result.notImplemented()
                }
            }
    }
}
