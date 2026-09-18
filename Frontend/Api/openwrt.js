/*
 * Frontend/Api/openwrt.js — заглушка. OpenWRT пока не использует Dart-фронтенд.
 */
(function () {
    'use strict';
    console.warn('[api/openwrt] OpenWRT bridge is a stub');
    const EMPTY_TOKEN = '{"hasToken":false,"fetching":false,"message":"","progress":0}';
    const EMPTY_UPDATE = '{"update":false,"version":""}';
    window.api = {
        GetConfigsJson: () => '[]', SaveConfig: () => false, DeleteConfig: () => false,
        GetSettingsJson: () => '{}', SaveSettings: () => false,
        GetLogsJson: () => '[]', ClearLogs: () => false,
        GetStatusJson: () => '{"connected":false}',
        Connect: () => false, Disconnect: () => false,
        CheckCoreUpdate: () => EMPTY_UPDATE, UpdateCore: () => false, UpdateCoreAndWait: () => false,
        CheckLaLuneUpdate: () => EMPTY_UPDATE, OpenLaLuneReleases: () => false,
        GetVKTokenState: () => EMPTY_TOKEN, LoginVK: () => false, DeleteVKToken: () => false,
        RunVkAutoApiCalls: () => '{"error":"not supported"}',
        PollAutoApiResult: () => '{"pending":true}', FinishVkCalls: () => false,
        GetDeviceId: () => '', RegenerateDeviceId: () => '',
    };
})();
