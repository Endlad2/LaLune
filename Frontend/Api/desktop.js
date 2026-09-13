/*
 * Frontend/Api/desktop.js
 *
 * Мост Dart → Wails (Go). Все функции имеют одинаковые имена
 * во всех Api/*.js — чтобы Dart-код не приходилось менять под платформу.
 */
(function () {
    'use strict';

    function go() {
        if (window.go && window.go.main && window.go.main.App) {
            return window.go.main.App;
        }
        return null;
    }

    // Wails возвращает Promise. Держим кэш, чтобы Dart мог читать
    // значения синхронно (он ожидает string/bool, а не Promise).
    let cachedConfigs = '[]';
    let cachedSettings = '{}';
    let cachedLogs = '[]';
    let cachedStatus = '{"connected":false}';
    let cachedCoreUpdate = '{"update":false,"version":""}';
    let cachedLaLuneUpdate = '{"update":false,"version":""}';

    async function refresh() {
        const api = go();
        if (!api) return;
        try { cachedConfigs = await api.GetConfigsJson(); } catch (_) {}
        try { cachedSettings = await api.GetSettingsJson(); } catch (_) {}
        try { cachedLogs = await api.GetLogsJson(); } catch (_) {}
        try { cachedStatus = await api.GetStatusJson(); } catch (_) {}
    }

    setInterval(refresh, 1500);
    setTimeout(refresh, 200);

    window.api = {
        // ====== чтение (из кэша) ======
        GetConfigsJson: () => cachedConfigs,
        GetSettingsJson: () => cachedSettings,
        GetLogsJson: () => cachedLogs,
        GetStatusJson: () => cachedStatus,

        // ====== действия ======
        SaveConfig: (link) => {
            const api = go(); if (!api) return false;
            api.SaveConfig(link).then(() => refresh());
            return true;
        },
        DeleteConfig: (id) => {
            const api = go(); if (!api) return false;
            api.DeleteConfig(id).then(() => refresh());
            return true;
        },
        SaveSettings: (json) => {
            const api = go(); if (!api) return false;
            api.SaveSettings(json).then(() => refresh());
            return true;
        },
        ClearLogs: () => {
            const api = go(); if (!api) return false;
            api.ClearLogs().then(() => refresh());
            return true;
        },
        Connect: (id) => {
            const api = go(); if (!api) return false;
            api.Connect(id).then(() => refresh());
            return true;
        },
        Disconnect: () => {
            const api = go(); if (!api) return false;
            api.Disconnect().then(() => refresh());
            return true;
        },

        // ====== обновление ядра CSQTT ======
        // Возвращает кэшированный JSON: {"update":bool,"version":"..."}.
        // Dart синхронно читает. После вызова CheckCoreUpdate в фоне
        // обновляется кэш, и следующий тик polling видит актуальное значение.
        CheckCoreUpdate: () => {
            const api = go();
            if (api && api.CheckUpdate) {
                api.CheckUpdate().then((raw) => {
                    try {
                        cachedCoreUpdate = typeof raw === 'string' ? raw : JSON.stringify(raw);
                    } catch (_) {}
                }).catch(() => {});
            }
            return cachedCoreUpdate;
        },
        UpdateCore: () => {
            const api = go(); if (!api) return false;
            api.UpdateCore().then(() => refresh());
            return true;
        },
        UpdateCoreAndWait: () => {
            const api = go(); if (!api) return false;
            api.UpdateCoreAndWait().then(() => refresh());
            return true;
        },

        // ====== обновление LaLune ======
        // Возвращает кэшированный JSON: {"update":bool,"version":"..."}.
        CheckLaLuneUpdate: () => {
            const api = go();
            if (api && api.CheckLaLuneUpdate) {
                api.CheckLaLuneUpdate().then((raw) => {
                    try {
                        const v = typeof raw === 'string' ? raw : JSON.stringify(raw);
                        // Wails обернёт Go-структуру в JSON автоматически.
                        // Мы ожидаем поля remoteTag/hasUpdate/err,
                        // но во фронт отдаём унифицированный формат.
                        let tag = '';
                        let has = false;
                        try {
                            const j = JSON.parse(v);
                            tag = j.remoteTag || j.RemoteTag || '';
                            has = !!(j.hasUpdate || j.HasUpdate);
                        } catch (_) {}
                        cachedLaLuneUpdate = JSON.stringify({ update: has, version: tag });
                    } catch (_) {}
                }).catch(() => {});
            }
            return cachedLaLuneUpdate;
        },
        OpenLaLuneReleases: () => {
            const api = go();
            if (api && api.OpenLaLuneReleasesURL) {
                api.OpenLaLuneReleasesURL().then((url) => {
                    try { window.open(url, '_blank'); } catch (_) {}
                }).catch(() => {});
                return true;
            }
            // Fallback — открываем напрямую
            try {
                window.open('https://github.com/Endlad2/LaLune/releases/latest', '_blank');
                return true;
            } catch (_) {
                return false;
            }
        },

        // ====== Device ID ======
        GetDeviceId: () => {
            try {
                const s = JSON.parse(cachedSettings);
                return s.deviceId || '';
            } catch (_) { return ''; }
        },
        RegenerateDeviceId: () => '',
    };

    console.log('[api/desktop] Wails bridge ready');
})();
