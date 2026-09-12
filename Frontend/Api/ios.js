/*
 * Frontend/Api/ios.js
 *
 * Мост Dart → WKWebView (webkit.messageHandlers.lalune).
 * iOS-версия пока не готова, поэтому возвращаем пустые данные.
 */
(function () {
    'use strict';

    console.warn('[api/ios] iOS bridge is a stub');

    window.api = {
        GetConfigsJson: () => '[]',
        SaveConfig: () => false,
        DeleteConfig: () => false,
        GetSettingsJson: () => '{}',
        SaveSettings: () => false,
        GetLogsJson: () => '[]',
        ClearLogs: () => false,
        GetStatusJson: () => '{"connected":false}',
        Connect: () => false,
        Disconnect: () => false,
        CheckUpdate: () => '{"update":false,"version":""}',
        UpdateCore: () => false,
        UpdateCoreAndWait: () => false,
        GetDeviceId: () => '',
        RegenerateDeviceId: () => '',
    };
})();
