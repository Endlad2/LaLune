/*
 * Frontend/Api/android.js — мост Dart → Kotlin AndroidBridge.
 *
 * VkLogin — открывает WebView с OAuth ВК через LaLuneTokenFetcherAndroid.
 * Токен сохраняется в token.json (ключ Token) — единый формат с Desktop.
 */
(function () {
    'use strict';

    function lalune() {
        if (typeof window.lalune === 'undefined') return null;
        return window.lalune;
    }

    let cachedVKTokenState = '{"hasToken":false,"fetcherOk":false,"fetching":false,"message":"","progress":0}';
    let cachedSelectedConfig = '{}';

    window.api = {
        GetConfigsJson: () => { const l = lalune(); if (!l) return '[]'; try { return l.getConfigs(); } catch (_) { return '[]'; } },
        SaveConfig: (link) => { const l = lalune(); if (!l) return false; try { return l.saveConfig(link); } catch (_) { return false; } },
        DeleteConfig: (id) => { const l = lalune(); if (!l) return false; try { return l.deleteConfig(id); } catch (_) { return false; } },
        GetSettingsJson: () => { const l = lalune(); if (!l) return '{}'; try { return l.getSettings(); } catch (_) { return '{}'; } },
        SaveSettings: (json) => { const l = lalune(); if (!l) return false; try { return l.saveSettings(json); } catch (_) { return false; } },
        GetLogsJson: () => { const l = lalune(); if (!l) return '[]'; try { return l.getLogs(); } catch (_) { return '[]'; } },
        ClearLogs: () => { const l = lalune(); if (!l) return false; try { return l.clearLogs(); } catch (_) { return false; } },
        GetStatusJson: () => { const l = lalune(); if (!l) return '{"connected":false}'; try { return l.getStatus(); } catch (_) { return '{"connected":false}'; } },
        Connect: (id) => { const l = lalune(); if (!l) return false; try { return l.connect(id); } catch (_) { return false; } },
        Disconnect: () => { const l = lalune(); if (!l) return false; try { return l.disconnect(); } catch (_) { return false; } },

        SetSelectedConfigJson: (json) => {
            const l = lalune();
            if (l && typeof l.setSelectedConfigJson === 'function') {
                try { return l.setSelectedConfigJson(json); } catch (_) {}
            }
            try { cachedSelectedConfig = json; } catch (_) {}
            return true;
        },
        GetSelectedConfigJson: () => {
            const l = lalune();
            if (l && typeof l.getSelectedConfigJson === 'function') {
                try {
                    const r = l.getSelectedConfigJson();
                    cachedSelectedConfig = r;
                    return r;
                } catch (_) {}
            }
            return cachedSelectedConfig;
        },

        IsCoreDownloading: () => {
            const l = lalune();
            if (l && typeof l.isCoreDownloading === 'function') {
                try { return l.isCoreDownloading(); } catch (_) {}
            }
            return false;
        },

        // ---------- ядро: на Android update НЕ поддерживается ----------
        CheckCoreUpdate: () => '{"update":false,"version":""}',
        UpdateCore: () => false,
        UpdateCoreAndWait: () => false,

        CheckLaLuneUpdate: () => {
            const l = lalune(); if (!l) return '{"update":false,"version":"0.5.0"}';
            try {
                if (typeof l.checkLaLuneUpdate === 'function') return l.checkLaLuneUpdate();
            } catch (_) {}
            return '{"update":false,"version":"0.5.0"}';
        },
        OpenLaLuneReleases: () => {
            const l = lalune();
            if (l && typeof l.openLaLuneReleases === 'function') {
                try { return l.openLaLuneReleases(); } catch (_) {}
            }
            try {
                window.open('https://github.com/Endlad2/LaLune/releases/latest', '_blank');
                return true;
            } catch (_) { return false; }
        },

        // ---------- VK авторизация ----------
        GetVKTokenState: () => {
            const l = lalune(); if (!l) return cachedVKTokenState;
            try {
                if (typeof l.getVKTokenState === 'function') {
                    const result = l.getVKTokenState();
                    cachedVKTokenState = result;
                    return result;
                }
            } catch (_) {}
            return cachedVKTokenState;
        },

        // VkLogin — открывает нативный WebView с OAuth ВК.
        // После успеха Kotlin сохраняет токен в token.json и вызывает
        // window._vkLoginCallback(true, token) через evaluateJavascript.
        VkLogin: () => {
            const l = lalune();
            if (!l) return false;
            try {
                if (typeof l.vkLogin === 'function') {
                    return l.vkLogin();
                }
            } catch (_) {}
            return false;
        },

        DeleteVKToken: () => {
            const l = lalune(); if (!l) return false;
            try {
                if (typeof l.deleteVKToken === 'function') return l.deleteVKToken();
            } catch (_) {}
            return false;
        },

        ValidateVKToken: () => {
            const l = lalune(); if (!l) return cachedVKTokenState;
            try {
                if (typeof l.validateVKToken === 'function') {
                    cachedVKTokenState = l.validateVKToken();
                    return cachedVKTokenState;
                }
                if (typeof l.getVKTokenState === 'function') {
                    cachedVKTokenState = l.getVKTokenState();
                    return cachedVKTokenState;
                }
            } catch (_) {}
            return cachedVKTokenState;
        },

        RunVkAutoApiCalls: () => {
            const l = lalune(); if (!l) return '{"error":"not supported"}';
            try {
                if (typeof l.runVkAutoApiCalls === 'function') return l.runVkAutoApiCalls();
            } catch (_) {}
            return '{"error":"not supported"}';
        },
        PollAutoApiResult: () => {
            const l = lalune(); if (!l) return '{"pending":true}';
            try {
                if (typeof l.pollAutoApiResult === 'function') return l.pollAutoApiResult();
            } catch (_) {}
            return '{"pending":true}';
        },
        FinishVkCalls: (callIdsJson) => {
            const l = lalune(); if (!l) return false;
            try {
                if (typeof l.finishVkCalls === 'function') return l.finishVkCalls(callIdsJson);
            } catch (_) {}
            return false;
        },

        GetDeviceId: () => { const l = lalune(); if (!l) return ''; try { return l.getDeviceId(); } catch (_) { return ''; } },
        RegenerateDeviceId: () => { const l = lalune(); if (!l) return ''; try { return l.regenerateDeviceId(); } catch (_) { return ''; } },
    };

    // Callback из Kotlin — вызывается после успешной авторизации.
    window._vkLoginCallback = function (success, payload) {
        console.log('[vk-login] callback success=' + success + ' payload=' + payload);
        // Dart поллит ValidateVKToken — здесь только логируем.
    };

    console.log('[api/android] AndroidBridge ready (VkLogin → native WebView)');
})();
