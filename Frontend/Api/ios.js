// Frontend/Api/ios.js
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// JS-мост между Dart-фронтендом LaLune и нативным iOS-хостом
// (Mobile/IOS/Sources/App/ViewController.swift).
//
// ── Почему кэш ─────────────────────────────────────────────────────────
// Dart вызывает `window.api.*` СИНХРОННО (dart:js_interop external).
// WKWebView-мост асинхронный: `postMessage` → нативный код → ответ
// приходит позже через `window._iosCallback(id, value)`.
//
// Решение то же, что и в desktop.js для Wails: фоновый опрос раз в
// FAST_MS/SLOW_MS обновляет локальный кэш, а Dart читает уже готовые
// значения. Методы-команды (SaveConfig/Connect/...) возвращают
// оптимистичный `true` и просят хост выполнить действие.
//
// ── Протокол (см. ViewController.swift) ────────────────────────────────
//   webView.configuration.userContentController.add(self, name: "lalune")
//
//   JS → native:  window.webkit.messageHandlers.lalune.postMessage({
//                     method: "getConfigs", callbackId: "cb_1", ...
//                 })
//
//   native → JS:  window._iosCallback("cb_1", "<result>")
//                 window._iosStatus(true|false)     // пуш статуса VPN
//                 window._iosLog("<line>")          // пуш строки лога
//
// Поддерживаемые методы на нативной стороне:
//   getConfigs, getSettings, getLogs, getStatus
//   saveConfig, deleteConfig, saveSettings
//   connect, disconnect, clearLogs
//   updateCore, checkUpdate, updateCoreAndWait
//
// Неизвестные методы хост возвращает как "false" — обёртки ниже
// деградируют мягко, без исключений.

(function () {
  'use strict';

  if (typeof window === 'undefined') return;

  var BRIDGE_NAME = 'lalune';

  // Быстрый цикл: конфиги / настройки / статус.
  var FAST_MS = 1500;
  // Медленный цикл: логи (могут быть большими).
  var SLOW_MS = 4000;
  // Страховочный таймаут на один postMessage.
  var CALLBACK_TIMEOUT_MS = 10000;

  // ──────────────────────────────────────────────────────────────
  //  Кэш синхронных ответов
  // ──────────────────────────────────────────────────────────────
  var cache = {
    configs: '[]',
    settings: '{}',
    logs: '[]',
    status: '{"connected":false}',
    selectedConfig: '{}',
    deviceId: '',
    coreDownloading: false,
    vkTokenState:
      '{"hasToken":false,"fetcherOk":true,"fetching":false,"message":"","progress":0}',
    coreUpdate: '{"update":false,"version":""}',
    laluneUpdate: '{"update":false,"version":"0.5.0"}'
  };

  // ──────────────────────────────────────────────────────────────
  //  Callback registry
  // ──────────────────────────────────────────────────────────────
  var nextId = 1;
  var pending = Object.create(null);

  function hasBridge() {
    return !!(window.webkit &&
              window.webkit.messageHandlers &&
              window.webkit.messageHandlers[BRIDGE_NAME]);
  }

  /**
   * Отправить сообщение нативной стороне. Возвращает Promise со строкой
   * ответа (или null, если моста нет / таймаут).
   */
  function post(method, extra) {
    return new Promise(function (resolve) {
      if (!hasBridge()) {
        resolve(null);
        return;
      }

      var id = 'cb_' + (nextId++);
      var timer = null;

      pending[id] = function (result) {
        if (timer !== null) {
          clearTimeout(timer);
          timer = null;
        }
        delete pending[id];
        resolve(result);
      };

      timer = setTimeout(function () {
        if (pending[id]) {
          delete pending[id];
          resolve(null);
        }
      }, CALLBACK_TIMEOUT_MS);

      var body = { method: method, callbackId: id };
      if (extra) {
        for (var k in extra) {
          if (Object.prototype.hasOwnProperty.call(extra, k)) {
            body[k] = extra[k];
          }
        }
      }

      try {
        window.webkit.messageHandlers[BRIDGE_NAME].postMessage(body);
      } catch (e) {
        if (timer !== null) {
          clearTimeout(timer);
          timer = null;
        }
        delete pending[id];
        resolve(null);
      }
    });
  }

  // ──────────────────────────────────────────────────────────────
  //  Точки входа, которые вызывает Swift
  // ──────────────────────────────────────────────────────────────

  // ViewController.sendCallback() → window._iosCallback(id, result)
  window._iosCallback = function (callbackId, result) {
    var fn = pending[callbackId];
    if (fn) fn(result);
  };

  // ViewController.sendStatus() → window._iosStatus(connected)
  // Это «пуш» из нативного слоя при старте/останове туннеля — обновляем
  // кэш сразу, не дожидаясь следующего опроса.
  window._iosStatus = function (connected) {
    cache.status = connected ? '{"connected":true}' : '{"connected":false}';
  };

  // ViewController.sendLog() → window._iosLog(line)
  // Отдельный буфер не ведём: логи и так читаются опросом getLogs из тех
  // же файлов, а смешивание push-строк с poll-снимком дало бы дубликаты.
  window._iosLog = function (_line) { /* см. комментарий выше */ };

  // ──────────────────────────────────────────────────────────────
  //  Хелперы
  // ──────────────────────────────────────────────────────────────
  function pickString(value, fallback) {
    if (typeof value === 'string' && value.length > 0) return value;
    return fallback;
  }

  function toBool(value) {
    if (value === true) return true;
    if (typeof value === 'string') return value === 'true';
    return false;
  }

  function pullDeviceId(settingsJson) {
    try {
      var parsed = JSON.parse(settingsJson);
      if (parsed && typeof parsed.deviceId === 'string') {
        cache.deviceId = parsed.deviceId;
      }
    } catch (_) { /* ignore */ }
  }

  // ──────────────────────────────────────────────────────────────
  //  Фоновый опрос
  // ──────────────────────────────────────────────────────────────
  function refreshFast() {
    post('getConfigs').then(function (r) {
      cache.configs = pickString(r, cache.configs);
    });

    post('getSettings').then(function (r) {
      var s = pickString(r, null);
      if (s !== null) {
        cache.settings = s;
        pullDeviceId(s);
      }
    });

    post('getStatus').then(function (r) {
      cache.status = pickString(r, cache.status);
    });
  }

  function refreshSlow() {
    post('getLogs').then(function (r) {
      cache.logs = pickString(r, cache.logs);
    });
  }

  function startLoops() {
    // Первый прогон — сразу, чтобы не ждать FAST_MS на старте.
    refreshFast();
    refreshSlow();

    setInterval(refreshFast, FAST_MS);
    setInterval(refreshSlow, SLOW_MS);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startLoops);
  } else {
    startLoops();
  }

  // ──────────────────────────────────────────────────────────────
  //  window.api — синхронный контракт для Dart
  // ──────────────────────────────────────────────────────────────

  var api = {

    // ── Конфиги ────────────────────────────────────────────────
    GetConfigsJson: function () {
      return cache.configs;
    },

    SaveConfig: function (link, protocol) {
      post('saveConfig', { link: String(link), protocol: String(protocol || 'CSQTT') }).then(function (r) {
        if (toBool(r)) refreshFast();
      });
      return true;
    },

    DeleteConfig: function (id) {
      post('deleteConfig', { id: Number(id) }).then(function (r) {
        if (toBool(r)) refreshFast();
      });
      return true;
    },

    // ── Настройки ──────────────────────────────────────────────
    GetSettingsJson: function () {
      return cache.settings;
    },

    SaveSettings: function (json) {
      post('saveSettings', { settings: String(json) }).then(function (r) {
        if (toBool(r)) refreshFast();
      });
      return true;
    },

    // ── Логи ───────────────────────────────────────────────────
    GetLogsJson: function () {
      return cache.logs;
    },

    ClearLogs: function () {
      post('clearLogs').then(function () { refreshSlow(); });
      return true;
    },

    // ── Статус / VPN ───────────────────────────────────────────
    GetStatusJson: function () {
      return cache.status;
    },

    Connect: function (configId) {
      post('connect', { configId: Number(configId) });
      // Оптимистично — натив отдаст актуальный статус через _iosStatus.
      cache.status = '{"connected":true}';
      return true;
    },

    Disconnect: function () {
      post('disconnect');
      cache.status = '{"connected":false}';
      return true;
    },

    // ── Обновления ядра ────────────────────────────────────────
    CheckCoreUpdate: function () {
      return cache.coreUpdate;
    },

    // Алиас: некоторые платформы исторически называли метод CheckUpdate.
    CheckUpdate: function () {
      return cache.coreUpdate;
    },

    UpdateCore: function () {
      post('updateCore');
      return true;
    },

    UpdateCoreAndWait: function () {
      post('updateCoreAndWait');
      return true;
    },

    // ── Обновления LaLune ──────────────────────────────────────
    CheckLaLuneUpdate: function () {
      return cache.laluneUpdate;
    },

    OpenLaLuneReleases: function () {
      // Нативная сторона откроет URL через UIApplication.open(_:).
      post('openLaLuneReleases');
      return true;
    },

    // ── VK-токен ───────────────────────────────────────────────
    GetVKTokenState: function () {
      return cache.vkTokenState;
    },

    ValidateVKToken: function () {
      return cache.vkTokenState;
    },

    VkLogin: function () {
      // На iOS вход в VK через ASWebAuthenticationSession пока не
      // реализован — хост вернёт "false", UI покажет «не завершено».
      post('vkLogin');
      return true;
    },

    DeleteVKToken: function () {
      post('deleteVKToken');
      cache.vkTokenState =
        '{"hasToken":false,"fetcherOk":true,"fetching":false,"message":"","progress":0}';
      return true;
    },

    RunVkAutoApiCalls: function () {
      // Авто-API (создание VK-звонков) на iOS-хосте не поддержан.
      return '{"error":"not supported"}';
    },

    PollAutoApiResult: function () {
      return '{"pending":false}';
    },

    FinishVkCalls: function (callIdsJson) {
      post('finishVkCalls', { callIds: String(callIdsJson) });
      return true;
    },

    // ── Device ID ──────────────────────────────────────────────
    GetDeviceId: function () {
      return cache.deviceId;
    },

    RegenerateDeviceId: function () {
      post('regenerateDeviceId').then(function (r) {
        var s = pickString(r, null);
        if (s !== null) cache.deviceId = s;
      });
      return cache.deviceId;
    },

    // ── Глобально выбранный конфиг ─────────────────────────────
    SetSelectedConfigJson: function (json) {
      cache.selectedConfig = String(json);
      post('setSelectedConfig', { json: String(json) });
      return true;
    },

    GetSelectedConfigJson: function () {
      return cache.selectedConfig;
    },

    // ── Прочее ─────────────────────────────────────────────────
    IsCoreDownloading: function () {
      return cache.coreDownloading;
    }
  };

  window.api = api;

  // Небольшая диагностика — видно в Xcode-консоли / Safari Web Inspector.
  try {
    console.log('[ios.js] bridge ready, webkit=' + hasBridge());
  } catch (_) { /* ignore */ }
})();
