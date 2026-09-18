// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// FlutterBridge — обработчик MethodChannel для iOS.
// Скелет: все методы возвращают заглушки, реальные вызовы подключаются позже.

import Flutter
import Foundation

final class FlutterBridge {
    static let shared = FlutterBridge()
    private init() {}

    func register(on channel: FlutterMethodChannel) {
        channel.setMethodCallHandler { call, result in
            self.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getConfigs":
            result("[]")
        case "saveConfig", "deleteConfig", "saveSettings", "clearLogs",
             "connect", "disconnect", "updateCore", "updateCoreAndWait",
             "openLaLuneReleases", "vkLogin", "deleteVKToken",
             "finishVkCalls", "setSelectedConfigJson":
            result(true)
        case "getSettings", "getSelectedConfigJson":
            result("{}")
        case "getLogs":
            result("[]")
        case "getStatus":
            result("{\"connected\":false}")
        case "checkCoreUpdate", "checkLaLuneUpdate":
            result("{\"update\":false,\"version\":\"\"}")
        case "getVKTokenState", "validateVKToken":
            result("{\"hasToken\":false,\"fetcherOk\":false,\"fetching\":false,\"message\":\"\",\"progress\":0}")
        case "runVkAutoApiCalls":
            result("{\"error\":\"ios not supported\"}")
        case "pollAutoApiResult":
            result("{\"pending\":false}")
        case "getDeviceId", "regenerateDeviceId":
            result("")
        case "isCoreDownloading":
            result(false)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
