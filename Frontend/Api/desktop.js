/*
 * Frontend/Api/desktop.js — мост Dart → Wails (Go).
 *
 * VkLogin — запускает LaLuneTokenFetcher.exe через Go-биндинг LoginVK.
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
    let cachedSelectedConfig = '{}';
    let cachedCoreDownloading = false;

    async function refresh() {
        const api = go();
        if (!api) return;
        try { cachedConfigs = await api.GetConfigsJson(); } catch (_) {}
        try { cachedSettings = await api.GetSettingsJson(); } catch (_) {}
        try { cachedLogs = await api.GetLogsJson(); } catch (_) {}
        try { cachedStatus = await api.GetStatusJson(); } catch (_) {}
        try { cachedSelectedConfig = await api.GetSelectedConfigJson(); } catch (_) {}
        try { cachedCoreDownloading = await api.IsCoreDownloading(); } catch (_) {}
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

        SetSelectedConfigJson: (json) => {
            const api = go();
            if (api && api.SetSelectedConfigJson) {
                try { api.SetSelectedConfigJson(json); } catch (_) {}
            }
            try { cachedSelectedConfig = json; } catch (_) {}
            return true;
        },
        GetSelectedConfigJson: () => {
            const api = go();
            if (api && api.GetSelectedConfigJson) {
                api.GetSelectedConfigJson().then((raw) => {
                    try {
                        cachedSelectedConfig = typeof raw === 'string' ? raw : JSON.stringify(raw);
                    } catch (_) {}
                }).catch(() => {});
            }
            return cachedSelectedConfig;
        },

        IsCoreDownloading: () => {
            const api = go();
            if (api && api.IsCoreDownloading) {
                api.IsCoreDownloading().then((v) => {
                    cachedCoreDownloading = !!v;
                }).catch(() => {});
            }
            return cachedCoreDownloading;
        },

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

        // VkLogin — открывает LaLuneTokenFetcher.exe (Desktop).
        // На Android это же имя открывает WebView.
        VkLogin: () => {
            const api = go();
            if (api && api.LoginVK) {
                api.LoginVK().then(() => {}).catch(() => {});
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
        ValidateVKToken: () => {
            const api = go();
            if (api && api.ValidateVKToken) {
                api.ValidateVKToken().then((raw) => {
                    try {
                        cachedVKTokenState = typeof raw === 'string' ? raw : JSON.stringify(raw);
                    } catch (_) {}
                }).catch(() => {});
            }
            return cachedVKTokenState;
        },

        RunVkAutoApiCalls: () => {
            const api = go();
            if (api && api.RunVkAutoApiCalls) {
                const promise = api.RunVkAutoApiCalls();
                if (promise && typeof promise.then === 'function') {
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
