/*
 * Frontend/Api/android.js
 *
 * Мост Dart → Kotlin AndroidBridge (window.lalune.*).
 * Имена функций совпадают с desktop.js / openwrt.js.
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
        CheckUpdate: () => {
            const l = lalune(); if (!l) return '{"update":false,"version":""}';
            try { return l.checkUpdate(); } catch (_) { return '{"update":false,"version":""}'; }
        },
        UpdateCore: () => {
            const l = lalune(); if (!l) return false;
            try { return l.updateCore(); } catch (_) { return false; }
        },
        UpdateCoreAndWait: () => {
            const l = lalune(); if (!l) return false;
            try { return l.updateCoreAndWait(); } catch (_) { return false; }
        },
        GetDeviceId: () => {
            const l = lalune(); if (!l) return '';
            try { return l.getDeviceId(); } catch (_) { return ''; }
        },
        RegenerateDeviceId: () => {
            const l = lalune(); if (!l) return '';
            try { return l.regenerateDeviceId(); } catch (_) { return ''; }
        },
    };

    console.log('[api/android] AndroidBridge ready');
})();
