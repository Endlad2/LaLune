/*
 * Frontend/Api/openwrt.js — мост Dart → Go-веб-сервер LaLune для OpenWRT.
 *
 * Все запросы идут на /api/* того же origin (порт 6543).
 * Синхронные методы (GetConfigsJson и т.п.) читают из кэша, который
 * обновляется в фоне каждые 1.5 сек. Мутирующие методы (SaveConfig,
 * Connect и т.п.) шлют POST/DELETE и сразу дёргают refresh.
 */
(function () {
    'use strict';

    const BASE = '';          // тот же origin
    const REFRESH_MS = 1500;
    const OWRT_PORT = '6543'; // порт LaLune-owrt

    let cachedConfigs = '[]';
    let cachedSettings = '{}';
    let cachedLogs = '[]';
    let cachedStatus = '{"connected":false,"installerRunning":false,"coreRunning":false}';
    let cachedVkState = '{"hasToken":false,"fetcherOk":false,"fetching":false,"message":"","progress":0}';
    let cachedUpdate = '{"update":false,"version":""}';
    let cachedSelectedConfig = '{}';

    async function get(url) {
        const r = await fetch(BASE + url, { cache: 'no-store' });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return await r.text();
    }

    async function post(url, body) {
        const r = await fetch(BASE + url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: body ? JSON.stringify(body) : undefined,
        });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return await r.text();
    }

    async function del(url) {
        const r = await fetch(BASE + url, { method: 'DELETE' });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return await r.text();
    }

    async function refresh() {
        try { cachedConfigs = await get('/api/configs'); } catch (_) {}
        try { cachedSettings = await get('/api/settings'); } catch (_) {}
        try { cachedLogs = await get('/api/logs'); } catch (_) {}
        try { cachedStatus = await get('/api/status'); } catch (_) {}
        try { cachedVkState = await get('/api/vktoken'); } catch (_) {}
        try { cachedUpdate = await get('/api/updates'); } catch (_) {}
    }

    setInterval(refresh, REFRESH_MS);
    setTimeout(refresh, 200);

    // Определяем OpenWRT по URL: либо порт 6543, либо /api/status отвечает.
    // Порт — самый надёжный признак: LaLune-owrt всегда слушает 6543.
    function isOpenWRT() {
        try {
            if (window.location.port === OWRT_PORT) return true;
            // На случай обратного прокси — если этот мост загружен, значит
            // мы уже на OpenWRT-бэкенде.
            return typeof window.api !== 'undefined' &&
                   typeof window.api.SetVKToken === 'function' &&
                   window.location.port === OWRT_PORT;
        } catch (_) {
            return false;
        }
    }

    window.api = {
        // ---------- платформа ----------
        IsOpenWRT: () => isOpenWRT(),

        // ---------- конфиги ----------
        GetConfigsJson: () => cachedConfigs,

        SaveConfig: (link) => {
            post('/api/configs', { link }).then(refresh).catch(() => {});
            return true;
        },

        DeleteConfig: (id) => {
            del('/api/configs?id=' + encodeURIComponent(id)).then(refresh).catch(() => {});
            return true;
        },

        // ---------- настройки ----------
        GetSettingsJson: () => cachedSettings,

        SaveSettings: (json) => {
            let body;
            try { body = JSON.parse(json); } catch (_) { return false; }
            post('/api/settings', body).then(refresh).catch(() => {});
            return true;
        },

        // ---------- статус ----------
        GetStatusJson: () => cachedStatus,

        // ---------- логи ----------
        GetLogsJson: () => cachedLogs,

        ClearLogs: () => {
            post('/api/logs/clear').then(refresh).catch(() => {});
            return true;
        },

        // ---------- подключение ----------
        Connect: (id) => {
            post('/api/connect', { configId: Number(id) }).then(refresh).catch(() => {});
            return true;
        },

        Disconnect: () => {
            post('/api/disconnect').then(refresh).catch(() => {});
            return true;
        },

        // ---------- глобально выбранный конфиг ----------
        SetSelectedConfigJson: (json) => {
            try { cachedSelectedConfig = json; } catch (_) {}
            return true;
        },
        GetSelectedConfigJson: () => cachedSelectedConfig,

        // ---------- флаг «ядро скачивается» (на OpenWRT нет) ----------
        IsCoreDownloading: () => false,

        // ---------- обновление ядра ----------
        CheckCoreUpdate: () => cachedUpdate,
        UpdateCore: () => {
            post('/api/updates').then(refresh).catch(() => {});
            return true;
        },
        UpdateCoreAndWait: () => {
            post('/api/updates').then(refresh).catch(() => {});
            return true;
        },

        // ---------- обновление LaLune (заглушка) ----------
        CheckLaLuneUpdate: () => cachedUpdate,
        OpenLaLuneReleases: () => {
            try {
                window.open('https://github.com/Endlad2/LaLune/releases/latest', '_blank');
                return true;
            } catch (_) { return false; }
        },

        // ---------- VK-токен ----------
        GetVKTokenState: () => cachedVkState,

        // На OpenWRT токен вводится вручную — VkLogin не открывает окно.
        VkLogin: () => false,

        DeleteVKToken: () => {
            del('/api/vktoken').then(refresh).catch(() => {});
            return true;
        },

        ValidateVKToken: () => cachedVkState,

        // Прямая установка токена — используется UI-полем ввода.
        SetVKToken: (token) => {
            post('/api/vktoken', { token }).then(refresh).catch(() => {});
            return true;
        },

        // ---------- Авто API ----------
        RunVkAutoApiCalls: () => '{"error":"not supported on OpenWRT"}',
        PollAutoApiResult: () => '{"pending":false}',
        FinishVkCalls: () => false,

        // ---------- deviceId ----------
        GetDeviceId: () => {
            try {
                const s = JSON.parse(cachedSettings);
                return s.deviceId || '';
            } catch (_) { return ''; }
        },
        RegenerateDeviceId: () => '',
    };

    console.log('[api/openwrt] LaLune web bridge ready (port 6543)');
})();
