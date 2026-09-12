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

    // Wails возвращает Promise — оборачиваем в синхронный вид через
    // простую эвристику: возвращаем сразу результат, если он не Promise.
    // Dart-сторона работает как с синхронным API, но это допустимо,
    // потому что мы конвертируем Promise → блокирующий ответ нельзя.
    // Поэтому Dart должен получать уже готовые значения через кэш.
    //
    // В desktop.js мы делаем проще: держим кэш и перезагружаем его
    // по таймеру в фоне. Dart читает актуальное значение из кэша.

    let cachedConfigs = '[]';
    let cachedSettings = '{}';
    let cachedLogs = '[]';
    let cachedStatus = '{"connected":false}';

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

        // ====== действия (async → синхронный return через void) ======
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
        CheckUpdate: () => '{"update":false,"version":"—"}',
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

        // ====== Device ID ======
        GetDeviceId: () => {
            try {
                const s = JSON.parse(cachedSettings);
                return s.deviceId || '';
            } catch (_) { return ''; }
        },
        RegenerateDeviceId: () => '', // Wails сам не умеет — управляется через SaveSettings
    };

    console.log('[api/desktop] Wails bridge ready');
})();
