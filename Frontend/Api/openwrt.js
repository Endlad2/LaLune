/*
 * Frontend/Api/openwrt.js
 *
 * Мост Dart → HTTP API на роутере (go-бинарь OpenWRT-версии).
 * Пока заглушка: возвращает пустые данные. Когда появится HTTP-API —
 * перепишем на fetch('/cgi-bin/lalune/...').
 */
(function () {
    'use strict';

    console.warn('[api/openwrt] OpenWRT bridge is a stub — no backend yet');

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
