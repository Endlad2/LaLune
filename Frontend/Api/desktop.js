/*
 * Frontend/Api/desktop.js — мост Dart → Wails (Go).
 * Все методы с одинаковыми именами во всех Api/*.js.
 */
(function () {
    'use strict';

    function go() {
        if (window.go && window.go.main && window.go.main.App) {
            return window.go.main.App;
        }
        return null;
    }

    let cachedConfigs = '[]';
    let cachedSettings = '{}';
    let cachedLogs = '[]';
    let cachedStatus = '{"connected":false}';
    let cachedCoreUpdate = '{"update":false,"version":""}';
    let cachedLaLuneUpdate = '{"update":false,"version":""}';
    let cachedVKTokenState = '{"hasToken":false,"fetcherOk":false,"fetching":false,"message":"","progress":0}';

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
        GetConfigsJson: () => cachedConfigs,
        GetSettingsJson: () => cachedSettings,
        GetLogsJson: () => cachedLogs,
        GetStatusJson: () => cachedStatus,

        SaveConfig: (link) => {
            const api = go(); if (!api) return false;
            api.SaveConfig(link).then(refresh);
            return true;
        },
        DeleteConfig: (id) => {
            const api = go(); if (!api) return false;
            api.DeleteConfig(id).then(refresh);
            return true;
        },
        SaveSettings: (json) => {
            const api = go(); if (!api) return false;
            api.SaveSettings(json).then(refresh);
            return true;
        },
        ClearLogs: () => {
            const api = go(); if (!api) return false;
            api.ClearLogs().then(refresh);
            return true;
        },
        Connect: (id) => {
            const api = go(); if (!api) return false;
            api.Connect(id).then(refresh);
            return true;
        },
        Disconnect: () => {
            const api = go(); if (!api) return false;
            api.Disconnect().then(refresh);
            return true;
        },

        // ---------- обновление ядра ----------
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
            api.UpdateCore().then(refresh);
            return true;
        },
        UpdateCoreAndWait: () => {
            const api = go(); if (!api) return false;
            api.UpdateCoreAndWait().then(refresh);
            return true;
        },

        // ---------- обновление LaLune ----------
        CheckLaLuneUpdate: () => {
            const api = go();
            if (api && api.CheckLaLuneUpdate) {
                api.CheckLaLuneUpdate().then((raw) => {
                    try {
                        const v = typeof raw === 'string' ? raw : JSON.stringify(raw);
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
            try {
                window.open('https://github.com/Endlad2/LaLune/releases/latest', '_blank');
                return true;
            } catch (_) { return false; }
        },

        // ---------- VK авторизация ----------
        GetVKTokenState: () => {
            const api = go();
            if (api && api.GetVKTokenState) {
                api.GetVKTokenState().then((raw) => {
                    try {
                        cachedVKTokenState = typeof raw === 'string' ? raw : JSON.stringify(raw);
                    } catch (_) {}
                }).catch(() => {});
            }
            return cachedVKTokenState;
        },
        // LoginVK — запускает fetcher, состояние читается через GetVKTokenState.
        // Возвращает true, если процесс стартовал.
        LoginVK: () => {
            const api = go();
            if (api && api.LoginVK) {
                api.LoginVK().then(() => {
                    // Поллинг состояния — сделает UI сам через GetVKTokenState
                }).catch(() => {});
                return true;
            }
            return false;
        },
        DeleteVKToken: () => {
            const api = go();
            if (api && api.DeleteVKToken) {
                api.DeleteVKToken().then(refresh);
                return true;
            }
            return false;
        },

        // ---------- Auto API ----------
        // Создаёт звонки через VK API, сохраняет хеши, возвращает JSON
        // {"hashes":[...],"callIds":[...],"error":""}
        RunVkAutoApiCalls: () => {
            const api = go();
            if (api && api.RunVkAutoApiCalls) {
                // Wails 2 биндинги синхронны для скалярных типов, но для
                // массивов возвращают Promise. Здесь используем callback-паттерн
                // через глобальное событие.
                const promise = api.RunVkAutoApiCalls();
                if (promise && typeof promise.then === 'function') {
                    // Асинхронно — но Dart ждёт синхронно. Значит должен
                    // быть отдельный метод PollAutoApiResult.
                    window._autoApiPromise = promise;
                    return '{"pending":true}';
                }
                return typeof promise === 'string' ? promise : JSON.stringify(promise);
            }
            return '{"error":"not supported"}';
        },
        PollAutoApiResult: () => {
            if (window._autoApiPromise && window._autoApiResult === undefined) {
                window._autoApiPromise.then((raw) => {
                    window._autoApiResult = typeof raw === 'string' ? raw : JSON.stringify(raw);
                }).catch((e) => {
                    window._autoApiResult = JSON.stringify({ error: String(e) });
                });
            }
            return window._autoApiResult || '{"pending":true}';
        },
        FinishVkCalls: (callIdsJson) => {
            const api = go();
            if (api && api.FinishVkCalls) {
                try {
                    const ids = JSON.parse(callIdsJson);
                    api.FinishVkCalls(ids).then(refresh);
                } catch (_) {}
                return true;
            }
            return false;
        },

        // ---------- Device ID ----------
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
