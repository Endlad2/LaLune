/*
 * Frontend/Api/ios.js — мост Dart → Swift (WKWebView).
 *
 * ВАЖНО: на iOS обновление ядра недоступно — ядро уже вкомпилировано.
 * Все методы апдейта — заглушки.
 */
(function () {
    'use strict';

    console.warn('[api/ios] iOS bridge (update disabled)');

    const EMPTY_TOKEN_STATE = '{"hasToken":false,"fetching":false,"message":"","progress":0}';
    const EMPTY_UPDATE = '{"update":false,"version":""}';

    function webkit() {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lalune) {
            return window.webkit.messageHandlers.lalune;
        }
        return null;
    }

    const pending = new Map();
    let nextId = 1;

    window._iosCallback = function (callbackId, result) {
        const cb = pending.get(String(callbackId));
        if (cb) { pending.delete(String(callbackId)); try { cb(result); } catch (_) {} }
    };
    window._iosLog = function (msg) { console.log('[ios-bridge]', msg); };

    function send(method, args, cb) {
        const w = webkit();
        if (!w) { if (cb) cb(null); return; }
        const id = String(nextId++);
        const payload = Object.assign({ method: method, callbackId: id }, args || {});
        if (cb) pending.set(id, cb);
        try { w.postMessage(payload); } catch (_) { if (cb) { pending.delete(id); cb(null); } }
    }

    let cachedConfigs = '[]';
    let cachedSettings = '{}';
    let cachedLogs = '[]';
    let cachedStatus = '{"connected":false}';
    let cachedSelectedConfig = '{}';

    function refreshAll() {
        send('getConfigs', null, (r) => { if (r) cachedConfigs = r; });
        send('getSettings', null, (r) => { if (r) cachedSettings = r; });
        send('getLogs', null, (r) => { if (r) cachedLogs = r; });
        send('getStatus', null, (r) => { if (r) cachedStatus = r; });
        send('getSelectedConfigJson', null, (r) => { if (r) cachedSelectedConfig = r; });
    }
    setTimeout(refreshAll, 200);
    setInterval(refreshAll, 800);

    window.api = {
        // ---------- платформа ----------
        IsOpenWRT: () => false,

        GetConfigsJson: () => cachedConfigs,
        GetSettingsJson: () => cachedSettings,
        GetLogsJson: () => cachedLogs,
        GetStatusJson: () => cachedStatus,

        SaveConfig: (link) => { send('saveConfig', { link: String(link) }); setTimeout(refreshAll, 300); return true; },
        DeleteConfig: (id) => { send('deleteConfig', { id: Number(id) }); setTimeout(refreshAll, 300); return true; },
        SaveSettings: (json) => { send('saveSettings', { settings: String(json) }); setTimeout(refreshAll, 300); return true; },
        ClearLogs: () => { send('clearLogs'); setTimeout(refreshAll, 200); return true; },
        Connect: (id) => { send('connect', { configId: Number(id) }); setTimeout(refreshAll, 500); return true; },
        Disconnect: () => { send('disconnect'); setTimeout(refreshAll, 500); return true; },

        SetSelectedConfigJson: (json) => {
            send('setSelectedConfigJson', { json: String(json) });
            try { cachedSelectedConfig = json; } catch (_) {}
            return true;
        },
        GetSelectedConfigJson: () => cachedSelectedConfig,

        IsCoreDownloading: () => false,

        CheckCoreUpdate: () => EMPTY_UPDATE,
        UpdateCore: () => false,
        UpdateCoreAndWait: () => false,

        CheckLaLuneUpdate: () => EMPTY_UPDATE,
        OpenLaLuneReleases: () => {
            try {
                window.open('https://github.com/Endlad2/LaLune/releases/latest', '_blank');
                return true;
            } catch (_) { return false; }
        },

        GetVKTokenState: () => {
            let result = EMPTY_TOKEN_STATE;
            send('getVKTokenState', null, (r) => { if (r) result = r; });
            return result;
        },
        LoginVK: () => {
            send('loginVK');
            return true;
        },
        DeleteVKToken: () => {
            send('deleteVKToken');
            return true;
        },
        ValidateVKToken: () => {
            let result = EMPTY_TOKEN_STATE;
            send('validateVKToken', null, (r) => { if (r) result = r; });
            return result;
        },

        // SetVKToken на iOS не реализован — токен из &token= сохраняет Swift.

        RunVkAutoApiCalls: () => '{"error":"ios not supported"}',
        PollAutoApiResult: () => '{"pending":true}',
        FinishVkCalls: () => false,

        GetDeviceId: () => {
            try {
                const s = JSON.parse(cachedSettings);
                return s.deviceId || '';
            } catch (_) { return ''; }
        },
        RegenerateDeviceId: () => '',
    };
})();
