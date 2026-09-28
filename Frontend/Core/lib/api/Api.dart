// Api.dart — единая точка входа LaLune для всех платформ.
//
// Desktop (Linux/Windows): напрямую через C-ABI Rust-библиотеки lalune_backend.
// Android / iOS:            через MethodChannel "lalune/api".
//
// Имена методов совпадают для всех платформ — UI ничего не знает про
// детали платформы. Синхронные геттеры читают из кэша; кэш обновляется
// методами refresh*().

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
//  C ABI (Backend/src/lib.rs)
// ---------------------------------------------------------------------------

typedef _VoidC = ffi.Void Function();
typedef _VoidDart = void Function();

typedef _IntC = ffi.Int Function();
typedef _IntDart = int Function();

typedef _Int64ArgC = ffi.Int Function(ffi.Int64);
typedef _Int64ArgDart = int Function(int);

typedef _StrC = ffi.Pointer<ffi.Char> Function();
typedef _StrDart = ffi.Pointer<ffi.Char> Function();

typedef _SaveConfigC = ffi.Int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>);
typedef _SaveConfigDart = int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>);

typedef _StrArgC = ffi.Int Function(ffi.Pointer<ffi.Char>);
typedef _StrArgDart = int Function(ffi.Pointer<ffi.Char>);

typedef _FreeC = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Char>);

// ---------------------------------------------------------------------------
//  Общие константы
// ---------------------------------------------------------------------------

const int kDefaultWorkers = 9;
const int kMinWorkers = 1;
const int kMaxWorkers = 127;
const int kDefaultAutoApiWorkers = 9;
const int kMinAutoApiWorkers = 9;
const int kMaxAutoApiWorkers = 27;

// ---------------------------------------------------------------------------
//  Модели
// ---------------------------------------------------------------------------

class ConfigItem {
  final int id;
  final String protocol;
  final String peer;
  final String password;
  final String hashes;
  final String name;
  final String rawLink;

  ConfigItem({
    required this.id,
    required this.protocol,
    required this.peer,
    required this.password,
    required this.hashes,
    required this.name,
    this.rawLink = '',
  });

  factory ConfigItem.fromJson(Map<String, dynamic> j) => ConfigItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        protocol: (j['protocol'] ?? 'CSQTT') as String,
        peer: (j['peer'] ?? '') as String,
        password: (j['password'] ?? '') as String,
        hashes: (j['hashes'] ?? '') as String,
        name: (j['name'] ?? j['peer'] ?? '') as String,
        rawLink: (j['rawLink'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'protocol': protocol,
        'peer': peer,
        'password': password,
        'hashes': hashes,
        'name': name,
        'rawLink': rawLink,
      };
}

class Settings {
  final String peer;
  final String vkHashes;
  final String vkJsToken;
  final int workers;
  final int autoApiWorkers;
  final String password;
  final String obfs;
  final String fingerprint;
  final String clientIds;
  final String deviceId;
  final String authMode;
  final String turnTransport;
  final String turnHost;
  final String turnPort;
  final String captchaMode;
  final String vkAuthMode;
  final bool allowHashRedistribution;
  final bool validateVkHashes;
  final bool enableSmartTunnel;

  Settings({
    this.peer = '',
    this.vkHashes = '',
    this.vkJsToken = '',
    this.workers = kDefaultWorkers,
    this.autoApiWorkers = kDefaultAutoApiWorkers,
    this.password = '',
    this.obfs = 'audio',
    this.fingerprint = 'chrome',
    this.clientIds = '8202606,6287487',
    this.deviceId = '',
    this.authMode = 'manual',
    this.turnTransport = 'udp',
    this.turnHost = '',
    this.turnPort = '',
    this.captchaMode = 'auto',
    this.vkAuthMode = 'vkcalls',
    this.allowHashRedistribution = false,
    this.validateVkHashes = false,
    this.enableSmartTunnel = false,
  });

  factory Settings.fromJson(Map<String, dynamic> j) {
    var w = ((j['workers'] ?? kDefaultWorkers) as num).toInt();
    if (w < kMinWorkers) w = kMinWorkers;
    if (w > kMaxWorkers) w = kMaxWorkers;

    var aw = ((j['autoApiWorkers'] ?? kDefaultAutoApiWorkers) as num).toInt();
    if (aw < kMinAutoApiWorkers) aw = kMinAutoApiWorkers;
    if (aw > kMaxAutoApiWorkers) aw = kMaxAutoApiWorkers;

    return Settings(
      peer: (j['peer'] ?? '') as String,
      vkHashes: (j['vkHashes'] ?? '') as String,
      vkJsToken: (j['vkJsToken'] ?? '') as String,
      workers: w,
      autoApiWorkers: aw,
      password: (j['password'] ?? '') as String,
      obfs: (j['obfs'] ?? 'audio') as String,
      fingerprint: (j['fingerprint'] ?? 'chrome') as String,
      clientIds: (j['clientIds'] ?? '8202606,6287487') as String,
      deviceId: (j['deviceId'] ?? '') as String,
      authMode: (j['authMode'] ?? 'manual') as String,
      turnTransport: (j['turnTransport'] ?? 'udp') as String,
      turnHost: (j['turnHost'] ?? '') as String,
      turnPort: (j['turnPort'] ?? '') as String,
      captchaMode: (j['captchaMode'] ?? 'auto') as String,
      vkAuthMode: (j['vkAuthMode'] ?? 'vkcalls') as String,
      allowHashRedistribution: (j['allowHashRedistribution'] ?? false) as bool,
      validateVkHashes: (j['validateVkHashes'] ?? false) as bool,
      enableSmartTunnel: (j['enableSmartTunnel'] ?? false) as bool,
    );
  }

  Map<String, dynamic> toJson() => {
        'peer': peer,
        'vkHashes': vkHashes,
        'vkJsToken': vkJsToken,
        'workers': workers,
        'autoApiWorkers': autoApiWorkers,
        'password': password,
        'obfs': obfs,
        'fingerprint': fingerprint,
        'clientIds': clientIds,
        'deviceId': deviceId,
        'authMode': authMode,
        'turnTransport': turnTransport,
        'turnHost': turnHost,
        'turnPort': turnPort,
        'captchaMode': captchaMode,
        'vkAuthMode': vkAuthMode,
        'allowHashRedistribution': allowHashRedistribution,
        'validateVkHashes': validateVkHashes,
        'enableSmartTunnel': enableSmartTunnel,
      };

  Settings copyWith({
    String? peer, String? vkHashes, String? vkJsToken,
    int? workers, int? autoApiWorkers,
    String? password, String? obfs, String? fingerprint, String? clientIds,
    String? deviceId, String? authMode, String? turnTransport,
    String? turnHost, String? turnPort, String? captchaMode,
    String? vkAuthMode, bool? allowHashRedistribution, bool? validateVkHashes,
    bool? enableSmartTunnel,
  }) =>
      Settings(
        peer: peer ?? this.peer,
        vkHashes: vkHashes ?? this.vkHashes,
        vkJsToken: vkJsToken ?? this.vkJsToken,
        workers: workers ?? this.workers,
        autoApiWorkers: autoApiWorkers ?? this.autoApiWorkers,
        password: password ?? this.password,
        obfs: obfs ?? this.obfs,
        fingerprint: fingerprint ?? this.fingerprint,
        clientIds: clientIds ?? this.clientIds,
        deviceId: deviceId ?? this.deviceId,
        authMode: authMode ?? this.authMode,
        turnTransport: turnTransport ?? this.turnTransport,
        turnHost: turnHost ?? this.turnHost,
        turnPort: turnPort ?? this.turnPort,
        captchaMode: captchaMode ?? this.captchaMode,
        vkAuthMode: vkAuthMode ?? this.vkAuthMode,
        allowHashRedistribution:
            allowHashRedistribution ?? this.allowHashRedistribution,
        validateVkHashes: validateVkHashes ?? this.validateVkHashes,
        enableSmartTunnel: enableSmartTunnel ?? this.enableSmartTunnel,
      );
}

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

class VkTokenState {
  final bool hasToken;
  final bool fetcherOk;
  final bool fetching;
  final String message;
  final int progress;

  const VkTokenState({
    required this.hasToken,
    required this.fetcherOk,
    required this.fetching,
    required this.message,
    required this.progress,
  });

  static const empty = VkTokenState(
    hasToken: false,
    fetcherOk: false,
    fetching: false,
    message: '',
    progress: 0,
  );

  factory VkTokenState.fromJsonString(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return VkTokenState(
        hasToken: (j['hasToken'] ?? false) as bool,
        fetcherOk: (j['fetcherOk'] ?? false) as bool,
        fetching: (j['fetching'] ?? false) as bool,
        message: (j['message'] ?? '') as String,
        progress: ((j['progress'] ?? 0) as num).toInt(),
      );
    } catch (_) {
      return empty;
    }
  }
}

class AutoApiResult {
  final List<String> hashes;
  final List<String> callIds;
  final String error;
  final bool pending;

  const AutoApiResult({
    this.hashes = const [],
    this.callIds = const [],
    this.error = '',
    this.pending = false,
  });

  factory AutoApiResult.fromJsonString(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['pending'] == true) return const AutoApiResult(pending: true);
      return AutoApiResult(
        hashes: (j['hashes'] as List?)?.map((e) => e.toString()).toList() ?? [],
        callIds:
            (j['callIds'] as List?)?.map((e) => e.toString()).toList() ?? [],
        error: (j['error'] ?? '') as String,
      );
    } catch (_) {
      return const AutoApiResult(error: 'parse error');
    }
  }
}

class SelectedConfig {
  static ConfigItem? _current;
  static ConfigItem? get current => _current;

  static void set(ConfigItem? cfg) {
    _current = cfg;
    final raw = cfg == null ? '{}' : jsonEncode(cfg.toJson());
    if (_useFfi) {
      _ffiCall.setSelectedConfigJson(raw);
    } else {
      _channel.invokeMethod('SetSelectedConfigJson', {'json': raw});
    }
  }

  static void clear() => set(null);
}

// ---------------------------------------------------------------------------
//  Platform helpers
// ---------------------------------------------------------------------------

const MethodChannel _channel = MethodChannel('lalune/api');

bool get _useFfi => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

// ---------------------------------------------------------------------------
//  FFI bridge
// ---------------------------------------------------------------------------

class _FfiBridge {
  ffi.DynamicLibrary? _lib;

  ffi.DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (Platform.isWindows) {
      _lib = ffi.DynamicLibrary.open('lalune_backend.dll');
    } else if (Platform.isLinux) {
      _lib = ffi.DynamicLibrary.open('liblalune_backend.so');
    } else if (Platform.isMacOS) {
      _lib = ffi.DynamicLibrary.open('liblalune_backend.dylib');
    } else {
      throw UnsupportedError('FFI не поддерживается');
    }
    return _lib!;
  }

  late final _VoidDart init = _load()
      .lookupFunction<_VoidC, _VoidDart>('lalune_init');

  String _takeString(ffi.Pointer<ffi.Char> p) {
    if (p == ffi.nullptr) return '';
    final s = p.cast<Utf8>().toDartString();
    _free(p);
    return s;
  }

  late final _FreeDart _free =
      _load().lookupFunction<_FreeC, _FreeDart>('lalune_free');

  String getConfigsJson() => _takeString(
      _load().lookupFunction<_StrC, _StrDart>('lalune_get_configs_json')());

  int saveConfig(String link, String protocol) {
    final l = link.toNativeUtf8().cast<ffi.Char>();
    final p = protocol.toNativeUtf8().cast<ffi.Char>();
    try {
      return _load()
          .lookupFunction<_SaveConfigC, _SaveConfigDart>('lalune_save_config')(l, p);
    } finally {
      calloc.free(l);
      calloc.free(p);
    }
  }

  int deleteConfig(int id) => _load()
      .lookupFunction<_Int64ArgC, _Int64ArgDart>('lalune_delete_config')(id);

  String getSettingsJson() => _takeString(
      _load().lookupFunction<_StrC, _StrDart>('lalune_get_settings_json')());

  int saveSettings(String json) {
    final p = json.toNativeUtf8().cast<ffi.Char>();
    try {
      return _load().lookupFunction<_StrArgC, _StrArgDart>('lalune_save_settings')(p);
    } finally {
      calloc.free(p);
    }
  }

  String getLogsJson() =>
      _takeString(_load().lookupFunction<_StrC, _StrDart>('lalune_get_logs_json')());

  int clearLogs() => _load().lookupFunction<_IntC, _IntDart>('lalune_clear_logs')();

  String getDeviceId() =>
      _takeString(_load().lookupFunction<_StrC, _StrDart>('lalune_get_device_id')());

  String regenerateDeviceId() => _takeString(
      _load().lookupFunction<_StrC, _StrDart>('lalune_regenerate_device_id')());

  int setSelectedConfigJson(String json) {
    final p = json.toNativeUtf8().cast<ffi.Char>();
    try {
      return _load().lookupFunction<_StrArgC, _StrArgDart>(
          'lalune_set_selected_config_json')(p);
    } finally {
      calloc.free(p);
    }
  }

  String getSelectedConfigJson() => _takeString(
      _load().lookupFunction<_StrC, _StrDart>('lalune_get_selected_config_json')());

  int connect(int id) => _load()
      .lookupFunction<_Int64ArgC, _Int64ArgDart>('lalune_connect')(id);

  int disconnect() =>
      _load().lookupFunction<_IntC, _IntDart>('lalune_disconnect')();

  String getStatusJson() =>
      _takeString(_load().lookupFunction<_StrC, _StrDart>('lalune_get_status_json')());

  bool isCoreDownloading() => _load()
          .lookupFunction<_IntC, _IntDart>('lalune_is_core_downloading')() ==
      1;

  String getVkTokenStateJson() => _takeString(_load()
      .lookupFunction<_StrC, _StrDart>('lalune_get_vk_token_state_json')());

  int vkLogin() => _load().lookupFunction<_IntC, _IntDart>('lalune_vk_login')();

  int deleteVkToken() =>
      _load().lookupFunction<_IntC, _IntDart>('lalune_delete_vk_token')();

  String validateVkTokenJson() => _takeString(_load()
      .lookupFunction<_StrC, _StrDart>('lalune_validate_vk_token_json')());

  String runVkAutoApiCalls() => _takeString(_load()
      .lookupFunction<_StrC, _StrDart>('lalune_run_vk_auto_api_calls')());

  String checkCoreUpdateJson() => _takeString(_load()
      .lookupFunction<_StrC, _StrDart>('lalune_check_core_update_json')());

  String checkLaLuneUpdateJson() => _takeString(_load()
      .lookupFunction<_StrC, _StrDart>('lalune_check_lalune_update_json')());

  int updateCoreAndWait() => _load()
      .lookupFunction<_IntC, _IntDart>('lalune_update_core_and_wait')();

  String laluneReleasesUrl() => _takeString(_load()
      .lookupFunction<_StrC, _StrDart>('lalune_lalune_releases_url')());

  int deployProtocol(String json) {
    final p = json.toNativeUtf8().cast<ffi.Char>();
    try {
      return _load().lookupFunction<_StrArgC, _StrArgDart>(
          'lalune_deploy_protocol')(p);
    } finally {
      calloc.free(p);
    }
  }

  String deployLog() =>
      _takeString(_load().lookupFunction<_StrC, _StrDart>('lalune_deploy_log')());

  bool isDeploying() => _load()
          .lookupFunction<_IntC, _IntDart>('lalune_is_deploying')() ==
      1;
}

final _FfiBridge _ffiCall = _FfiBridge();

// ---------------------------------------------------------------------------
//  Api — единая точка входа
// ---------------------------------------------------------------------------

class Api {
  Api._();

  static void init() {
    if (_useFfi) {
      _ffiCall.init();
    }
  }

  // -------------------- Configs --------------------

  static List<ConfigItem> _configs = [];
  static List<ConfigItem> getConfigs() => _configs;

  static Future<void> refreshConfigs() async {
    try {
      final raw = _useFfi
          ? _ffiCall.getConfigsJson()
          : await _channel.invokeMethod<String>('GetConfigsJson');
      if (raw == null || raw.isEmpty) return;
      final arr = jsonDecode(raw) as List;
      _configs = arr
          .map((e) => ConfigItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  static Future<bool> saveConfig(String link, [String protocol = 'CSQTT']) async {
    try {
      if (_useFfi) {
        return _ffiCall.saveConfig(link, protocol) == 0;
      }
      final ok = await _channel.invokeMethod<bool>(
        'SaveConfig',
        {'link': link, 'protocol': protocol},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> deleteConfig(int id) async {
    try {
      if (_useFfi) {
        return _ffiCall.deleteConfig(id) == 0;
      }
      final ok = await _channel.invokeMethod<bool>('DeleteConfig', {'id': id});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // -------------------- Settings --------------------

  static Settings _settings = Settings();
  static Settings getSettings() => _settings;

  static Future<void> refreshSettings() async {
    try {
      final raw = _useFfi
          ? _ffiCall.getSettingsJson()
          : await _channel.invokeMethod<String>('GetSettingsJson');
      if (raw == null || raw.isEmpty) return;
      _settings = Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  static Future<bool> saveSettings(Settings s) async {
    try {
      final json = jsonEncode(s.toJson());
      if (_useFfi) {
        final ok = _ffiCall.saveSettings(json) == 0;
        if (ok) _settings = s;
        return ok;
      }
      final ok = await _channel.invokeMethod<bool>('SaveSettings', {'json': json});
      if (ok == true) _settings = s;
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // -------------------- Logs --------------------

  static List<String> _logs = [];
  static List<String> getLogs() => _logs;

  static Future<void> refreshLogs() async {
    try {
      final raw = _useFfi
          ? _ffiCall.getLogsJson()
          : await _channel.invokeMethod<String>('GetLogsJson');
      if (raw == null || raw.isEmpty) return;
      final arr = jsonDecode(raw) as List;
      _logs = arr.map((e) => e.toString()).toList();
    } catch (_) {}
  }

  static Future<bool> clearLogs() async {
    try {
      if (_useFfi) {
        _ffiCall.clearLogs();
        _logs = [];
        return true;
      }
      final ok = await _channel.invokeMethod<bool>('ClearLogs');
      if (ok == true) _logs = [];
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // -------------------- Status --------------------

  static bool _connected = false;
  static bool isConnected() => _connected;

  static Future<void> refreshStatus() async {
    try {
      final raw = _useFfi
          ? _ffiCall.getStatusJson()
          : await _channel.invokeMethod<String>('GetStatusJson');
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _connected = (j['connected'] ?? false) as bool;
    } catch (_) {}
  }

  static Future<bool> connect(int id) async {
    try {
      if (_useFfi) {
        final ok = _ffiCall.connect(id) == 0;
        if (ok) _connected = true;
        return ok;
      }
      final ok = await _channel.invokeMethod<bool>('Connect', {'id': id});
      if (ok == true) _connected = true;
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> disconnect() async {
    try {
      if (_useFfi) {
        _ffiCall.disconnect();
        _connected = false;
        return true;
      }
      final ok = await _channel.invokeMethod<bool>('Disconnect');
      _connected = false;
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // -------------------- Core / LaLune updates --------------------

  static UpdateInfo _coreUpdate = UpdateInfo.empty;
  static UpdateInfo checkCoreUpdate() => _coreUpdate;

  static Future<void> refreshCoreUpdate() async {
    try {
      final raw = _useFfi
          ? _ffiCall.checkCoreUpdateJson()
          : await _channel.invokeMethod<String>('CheckCoreUpdate');
      if (raw == null || raw.isEmpty) return;
      _coreUpdate = UpdateInfo.fromJsonString(raw);
    } catch (_) {}
  }

  static Future<bool> updateCoreAndWait() async {
    try {
      if (_useFfi) return _ffiCall.updateCoreAndWait() == 0;
      final ok = await _channel.invokeMethod<bool>('UpdateCoreAndWait');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static UpdateInfo _laluneUpdate = UpdateInfo.empty;
  static UpdateInfo checkLaLuneUpdate() => _laluneUpdate;

  static Future<void> refreshLaLuneUpdate() async {
    try {
      final raw = _useFfi
          ? _ffiCall.checkLaLuneUpdateJson()
          : await _channel.invokeMethod<String>('CheckLaLuneUpdate');
      if (raw == null || raw.isEmpty) return;
      _laluneUpdate = UpdateInfo.fromJsonString(raw);
    } catch (_) {}
  }

  static Future<bool> openLaLuneReleases() async {
    try {
      if (_useFfi) {
        // desktop открывает URL через url_launcher на UI-стороне
        return true;
      }
      final ok = await _channel.invokeMethod<bool>('OpenLaLuneReleases');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // -------------------- VK token --------------------

  static VkTokenState _vk = VkTokenState.empty;
  static VkTokenState getVKTokenState() => _vk;
  static VkTokenState validateVKToken() => _vk;

  static Future<void> refreshVkState() async {
    try {
      final raw = _useFfi
          ? _ffiCall.getVkTokenStateJson()
          : await _channel.invokeMethod<String>('GetVKTokenState');
      if (raw == null || raw.isEmpty) return;
      _vk = VkTokenState.fromJsonString(raw);
    } catch (_) {}
  }

  static Future<bool> vkLogin() async {
    try {
      if (_useFfi) return _ffiCall.vkLogin() == 0;
      final ok = await _channel.invokeMethod<bool>('VkLogin');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> deleteVKToken() async {
    try {
      if (_useFfi) {
        _ffiCall.deleteVkToken();
        _vk = VkTokenState.empty;
        return true;
      }
      final ok = await _channel.invokeMethod<bool>('DeleteVKToken');
      _vk = VkTokenState.empty;
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static AutoApiResult runVkAutoApiCalls() {
    try {
      if (_useFfi) {
        return AutoApiResult.fromJsonString(_ffiCall.runVkAutoApiCalls());
      }
      return const AutoApiResult(pending: true);
    } catch (_) {
      return const AutoApiResult(error: 'ffi error');
    }
  }

  static AutoApiResult pollAutoApiResult() {
    return const AutoApiResult(pending: false);
  }

  static Future<bool> finishVkCalls(List<String> callIds) async {
    try {
      if (_useFfi) return true;
      final ok = await _channel
          .invokeMethod<bool>('FinishVkCalls', {'callIds': callIds});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // -------------------- Device ID --------------------

  static String _deviceId = '';
  static String getDeviceId() => _deviceId;

  static Future<void> refreshDeviceId() async {
    try {
      final raw = _useFfi
          ? _ffiCall.getDeviceId()
          : await _channel.invokeMethod<String>('GetDeviceId');
      if (raw != null && raw.isNotEmpty) _deviceId = raw;
    } catch (_) {}
  }

  static Future<String> regenerateDeviceId() async {
    try {
      final raw = _useFfi
          ? _ffiCall.regenerateDeviceId()
          : await _channel.invokeMethod<String>('RegenerateDeviceId');
      if (raw != null && raw.isNotEmpty) _deviceId = raw;
      return _deviceId;
    } catch (_) {
      return _deviceId;
    }
  }

  // -------------------- Selected config --------------------

  static Future<void> setSelectedConfigJson(ConfigItem? cfg) async {
    SelectedConfig.set(cfg);
  }

  static ConfigItem? loadSelectedConfigFromJs() => SelectedConfig.current;

  // -------------------- Core downloading --------------------

  static bool _coreDownloading = false;
  static bool isCoreDownloading() => _coreDownloading;

  static Future<void> refreshCoreDownloading() async {
    try {
      if (_useFfi) {
        _coreDownloading = _ffiCall.isCoreDownloading();
        return;
      }
      final v = await _channel.invokeMethod<bool>('IsCoreDownloading');
      _coreDownloading = v ?? false;
    } catch (_) {}
  }

  // -------------------- Deploy --------------------

  static String _deployLog = '';
  static bool _deploying = false;

  static Future<bool> deploy(String json) async {
    try {
      if (_useFfi) {
        final ok = _ffiCall.deployProtocol(json) == 0;
        _deploying = ok;
        return ok;
      }
      final ok = await _channel.invokeMethod<bool>('DeployProtocol', {'json': json});
      _deploying = ok ?? false;
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static String deployLog() => _deployLog;
  static bool isDeploying() => _deploying;

  static Future<void> refreshDeployState() async {
    try {
      if (_useFfi) {
        _deployLog = _ffiCall.deployLog();
        _deploying = _ffiCall.isDeploying();
        return;
      }
      final log = await _channel.invokeMethod<String>('DeployLog');
      if (log != null) _deployLog = log;
      final busy = await _channel.invokeMethod<bool>('IsDeploying');
      _deploying = busy ?? false;
    } catch (_) {}
  }

  // -------------------- Bulk refresh --------------------

  static Future<void> refreshAll() async {
    await Future.wait([
      refreshConfigs(),
      refreshSettings(),
      refreshLogs(),
      refreshStatus(),
      refreshVkState(),
      refreshDeviceId(),
      refreshCoreDownloading(),
    ]);
  }
}

// Re-export, чтобы старый `typedef Uint8List` не ломал ничего.
typedef ApiUint8List = Uint8List;
