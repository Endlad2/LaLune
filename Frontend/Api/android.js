/*
 * Frontend/Api/android.js
 *
 * Мост Dart → Kotlin AndroidBridge (window.lalune.*).
 * Имена функций совпадают с desktop.js / ios.js / openwrt.js.
 *
 * Работает через https://appassets.androidplatform.net/assets/app.html —
 * то есть Fetch API, XHR, Service Worker и FontManifest.json грузятся
 * нормально (Kotlin использует WebViewAssetLoader).
 */
(function () {
    'use strict';

    function lalune() {
        if (typeof window.lalune === 'undefined') return null;
        return window.lalune;
    }

    window.api = {
        GetConfigsJson: () => {
            const l = lalune(); if (!l) return '[]';
            try { return l.getConfigs(); } catch (_) { return '[]'; }
        },
        SaveConfig: (link) => {
            const l = lalune(); if (!l) return false;
            try { return l.saveConfig(link); } catch (_) { return false; }
        },
        DeleteConfig: (id) => {
            const l = lalune(); if (!l) return false;
            try { return l.deleteConfig(id); } catch (_) { return false; }
        },
        GetSettingsJson: () => {
            const l = lalune(); if (!l) return '{}';
            try { return l.getSettings(); } catch (_) { return '{}'; }
        },
        SaveSettings: (json) => {
            const l = lalune(); if (!l) return false;
            try { return l.saveSettings(json); } catch (_) { return false; }
        },
        GetLogsJson: () => {
            const l = lalune(); if (!l) return '[]';
            try { return l.getLogs(); } catch (_) { return '[]'; }
        },
        ClearLogs: () => {
            const l = lalune(); if (!l) return false;
            try { return l.clearLogs(); } catch (_) { return false; }
        },
        GetStatusJson: () => {
            const l = lalune(); if (!l) return '{"connected":false}';
            try { return l.getStatus(); } catch (_) { return '{"connected":false}'; }
        },
        Connect: (id) => {
            const l = lalune(); if (!l) return false;
            try { return l.connect(id); } catch (_) { return false; }
        },
        Disconnect: () => {
            const l = lalune(); if (!l) return false;
            try { return l.disconnect(); } catch (_) { return false; }
        },

        // ====== проверка обновлений ядра CSQTT ======
        CheckCoreUpdate: () => {
            const l = lalune(); if (!l) return '{"update":false,"version":""}';
            try {
                if (typeof l.checkCoreUpdate === 'function') {
                    return l.checkCoreUpdate();
                }
                if (typeof l.checkUpdate === 'function') {
                    return l.checkUpdate();
                }
            } catch (_) {}
            return '{"update":false,"version":""}';
        },
        UpdateCore: () => {
            const l = lalune(); if (!l) return false;
            try { return l.updateCore(); } catch (_) { return false; }
        },
        UpdateCoreAndWait: () => {
            const l = lalune(); if (!l) return false;
            try { return l.updateCoreAndWait(); } catch (_) { return false; }
        },

        // ====== проверка обновлений LaLune ======
        CheckLaLuneUpdate: () => {
            const l = lalune(); if (!l) return '{"update":false,"version":"0.5.0"}';
            try {
                if (typeof l.checkLaLuneUpdate === 'function') {
                    return l.checkLaLuneUpdate();
                }
            } catch (_) {}
            return '{"update":false,"version":"0.5.0"}';
        },
        OpenLaLuneReleases: () => {
            const l = lalune(); if (!l) {
                // Fallback через window.open
                try {
                    window.open('https://github.com/Endlad2/LaLune/releases/latest', '_blank');
                    return true;
                } catch (_) { return false; }
            }
            try {
                if (typeof l.openLaLuneReleases === 'function') {
                    return l.openLaLuneReleases();
                }
            } catch (_) {}
            return false;
        },

        // ====== Device ID ======
        GetDeviceId: () => {
            const l = lalune(); if (!l) return '';
            try { return l.getDeviceId(); } catch (_) { return ''; }
        },
        RegenerateDeviceId: () => {
            const l = lalune(); if (!l) return '';
            try { return l.regenerateDeviceId(); } catch (_) { return ''; }
        },
    };

    console.log('[api/android] AndroidBridge ready (https origin)');
})();
