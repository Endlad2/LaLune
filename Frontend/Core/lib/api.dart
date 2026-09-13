// Тонкий мост Dart → JS.
//
// Все функции window.api возвращают либо строку, либо bool.
// Здесь просто обёртки для типобезопасности и единообразия.

import 'dart:convert';
import 'dart:js_interop';

// ---- Raw JS-функции --------------------------------------------------------

@JS('window.api.GetConfigsJson')
external String _getConfigsJson();

@JS('window.api.SaveConfig')
external bool _saveConfig(String link);

@JS('window.api.DeleteConfig')
external bool _deleteConfig(num id);

@JS('window.api.GetSettingsJson')
external String _getSettingsJson();

@JS('window.api.SaveSettings')
external bool _saveSettings(String json);

@JS('window.api.GetLogsJson')
external String _getLogsJson();

@JS('window.api.ClearLogs')
external bool _clearLogs();

@JS('window.api.GetStatusJson')
external String _getStatusJson();

@JS('window.api.Connect')
external bool _connect(num configId);

@JS('window.api.Disconnect')
external bool _disconnect();

@JS('window.api.CheckCoreUpdate')
external String _checkCoreUpdate();

@JS('window.api.UpdateCore')
external bool _updateCore();

@JS('window.api.UpdateCoreAndWait')
external bool _updateCoreAndWait();

@JS('window.api.CheckLaLuneUpdate')
external String _checkLaLuneUpdate();

@JS('window.api.OpenLaLuneReleases')
external bool _openLaLuneReleases();

@JS('window.api.GetDeviceId')
external String _getDeviceId();

@JS('window.api.RegenerateDeviceId')
external String _regenerateDeviceId();

// ---- Типы ------------------------------------------------------------------

class ConfigItem {
  final int id;
  final String protocol;
  final String peer;
  final String password;
  final String hashes;
  final String name;

  ConfigItem({
    required this.id,
    required this.protocol,
    required this.peer,
    required this.password,
    required this.hashes,
    required this.name,
  });

  factory ConfigItem.fromJson(Map<String, dynamic> j) => ConfigItem(
        id: (j['id'] as num).toInt(),
        protocol: (j['protocol'] ?? 'CSQTT') as String,
        peer: (j['peer'] ?? '') as String,
        password: (j['password'] ?? '') as String,
        hashes: (j['hashes'] ?? '') as String,
        name: (j['name'] ?? j['peer'] ?? '') as String,
      );
}

class Settings {
  final String peer;
  final String vkHashes;
  final String password;
  final int workersPerHash;
  final String obfs;
  final String fingerprint;
  final String clientIds;
  final String deviceId;

  Settings({
    this.peer = '',
    this.vkHashes = '',
    this.password = '',
    this.workersPerHash = 9,
    this.obfs = 'video',
    this.fingerprint = 'firefox',
    this.clientIds = '8202606,6287487',
    this.deviceId = '',
  });

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        peer: (j['peer'] ?? '') as String,
        vkHashes: (j['vkHashes'] ?? '') as String,
        password: (j['password'] ?? '') as String,
        workersPerHash: ((j['workersPerHash'] ?? 9) as num).toInt(),
        obfs: (j['obfs'] ?? 'video') as String,
        fingerprint: (j['fingerprint'] ?? 'firefox') as String,
        clientIds: (j['clientIds'] ?? '8202606,6287487') as String,
        deviceId: (j['deviceId'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'peer': peer,
        'vkHashes': vkHashes,
        'password': password,
        'workersPerHash': workersPerHash,
        'obfs': obfs,
        'fingerprint': fingerprint,
        'clientIds': clientIds,
        'deviceId': deviceId,
      };
}

/// Результат проверки обновлений (ядра или LaLune).
class UpdateInfo {
  final bool hasUpdate;
  final String version;

  const UpdateInfo({required this.hasUpdate, required this.version});

  static const empty = UpdateInfo(hasUpdate: false, version: '');

  factory UpdateInfo.fromJsonString(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return UpdateInfo(
        hasUpdate: (j['update'] ?? false) as bool,
        version: (j['version'] ?? '') as String,
      );
    } catch (_) {
      return empty;
    }
  }
}

// ---- Обёртки ---------------------------------------------------------------

class Api {
  static void init() {
    // Точка входа для будущих init-хендшейков
  }

  static List<ConfigItem> getConfigs() {
    try {
      final raw = _getConfigsJson();
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) => ConfigItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static bool saveConfig(String link) {
    try { return _saveConfig(link); } catch (_) { return false; }
  }

  static bool deleteConfig(int id) {
    try { return _deleteConfig(id); } catch (_) { return false; }
  }

  static Settings getSettings() {
    try {
      final raw = _getSettingsJson();
      return Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return Settings();
    }
  }

  static bool saveSettings(Settings s) {
    try {
      return _saveSettings(jsonEncode(s.toJson()));
    } catch (_) {
      return false;
    }
  }

  static List<String> getLogs() {
    try {
      final raw = _getLogsJson();
      final arr = jsonDecode(raw) as List;
      return arr.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  static bool clearLogs() {
    try { return _clearLogs(); } catch (_) { return false; }
  }

  static bool isConnected() {
    try {
      final raw = _getStatusJson();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (j['connected'] ?? false) as bool;
    } catch (_) {
      return false;
    }
  }

  static bool connect(int configId) {
    try { return _connect(configId); } catch (_) { return false; }
  }

  static bool disconnect() {
    try { return _disconnect(); } catch (_) { return false; }
  }

  // ====== обновление ядра CSQTT ======

  /// Синхронный "запрос" — возвращает кэш. Реальная проверка
  /// запускается в фоне внутри JS-моста, кэш обновляется
  /// через несколько секунд. UI должен дёргать повторно.
  static UpdateInfo checkCoreUpdate() {
    try { return UpdateInfo.fromJsonString(_checkCoreUpdate()); }
    catch (_) { return UpdateInfo.empty; }
  }

  static bool updateCore() {
    try { return _updateCore(); } catch (_) { return false; }
  }

  static bool updateCoreAndWait() {
    try { return _updateCoreAndWait(); } catch (_) { return false; }
  }

  // ====== обновление LaLune ======

  /// Проверка обновления LaLune через GitHub API.
  /// Синхронный доступ — читает кэш, обновляется в фоне.
  static UpdateInfo checkLaLuneUpdate() {
    try { return UpdateInfo.fromJsonString(_checkLaLuneUpdate()); }
    catch (_) { return UpdateInfo.empty; }
  }

  /// Открывает https://github.com/Endlad2/LaLune/releases/latest
  /// в системном браузере.
  static bool openLaLuneReleases() {
    try { return _openLaLuneReleases(); } catch (_) { return false; }
  }

  static String getDeviceId() {
    try { return _getDeviceId(); } catch (_) { return ''; }
  }

  static String regenerateDeviceId() {
    try { return _regenerateDeviceId(); } catch (_) { return ''; }
  }
}
