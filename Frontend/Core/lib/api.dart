// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// api.dart — единая точка входа для всей Dart-части.
//
// Три реализации под капотом:
//   1. Desktop (Linux/Windows): dart:ffi → liblalune.so / lalune.dll
//   2. Android: MethodChannel('com.lalune.app/bridge') → Kotlin
//   3. iOS: MethodChannel('com.lalune.app/bridge') → Swift
//
// Выбор реализации — через Platform.isAndroid/isIOS. Всё остальное в UI
// просто вызывает Api.getLogs(), Api.connect(id) и т.д.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform, Directory;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

// ============================================================
//  Публичные модели
// ============================================================

const int kDefaultWorkers = 9;
const int kMinWorkers = 1;
const int kMaxWorkers = 127;
const int kDefaultAutoApiWorkers = 9;
const int kMinAutoApiWorkers = 9;
const int kMaxAutoApiWorkers = 27;

class SelectedConfig {
  static ConfigItem? _current;
  static ConfigItem? get current => _current;

  static void set(ConfigItem? cfg) {
    _current = cfg;
    Api.setSelectedConfigJson(cfg == null ? '{}' : jsonEncode(cfg.toJson()));
  }

  static void clear() => set(null);
}

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
  }) => Settings(
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
    allowHashRedistribution: allowHashRedistribution ?? this.allowHashRedistribution,
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
    } catch (_) { return empty; }
  }
}

class VkTokenState {
  final bool hasToken;
  final bool fetcherOk;
  final bool fetching;
  final String message;
  final int progress;

  const VkTokenState({
    required this.hasToken, required this.fetcherOk, required this.fetching,
    required this.message, required this.progress,
  });

  static const empty = VkTokenState(
    hasToken: false, fetcherOk: false, fetching: false, message: '', progress: 0,
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
    } catch (_) { return empty; }
  }
}

class AutoApiResult {
  final List<String> hashes;
  final List<String> callIds;
  final String error;
  final bool pending;

  const AutoApiResult({
    this.hashes = const [], this.callIds = const [],
    this.error = '', this.pending = false,
  });

  factory AutoApiResult.fromJsonString(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['pending'] == true) return const AutoApiResult(pending: true);
      return AutoApiResult(
        hashes: (j['hashes'] as List?)?.map((e) => e.toString()).toList() ?? [],
        callIds: (j['callIds'] as List?)?.map((e) => e.toString()).toList() ?? [],
        error: (j['error'] ?? '') as String,
      );
    } catch (_) { return const AutoApiResult(error: 'parse error'); }
  }
}

// ============================================================
//  Платформенный backend
// ============================================================

abstract class _ApiBackend {
  Future<void> init();
  String getConfigsJson();
  bool saveConfig(String link);
  bool deleteConfig(int id);
  String getSettingsJson();
  bool saveSettings(String json);
  String getLogsJson();
  bool clearLogs();
  String getStatusJson();
  bool connect(int id);
  bool disconnect();
  String checkCoreUpdate();
  bool updateCore();
  bool updateCoreAndWait();
  String checkLaLuneUpdate();
  String openLaLuneReleases();
  String getVKTokenState();
  bool vkLogin();
  bool deleteVKToken();
  String validateVKToken();
  String runVkAutoApiCalls();
  String pollAutoApiResult();
  bool finishVkCalls(String callIdsJson);
  String getDeviceId();
  String regenerateDeviceId();
  String getSelectedConfigJson();
  bool setSelectedConfigJson(String json);
  bool isCoreDownloading();
}

// ------------------------------------------------------------
//  Desktop: dart:ffi
// ------------------------------------------------------------

typedef _CVoid = Void Function();
typedef _CInt = Int32 Function();
typedef _CIntFromLL = Int32 Function(Int64);
typedef _CIntFromPtr = Int32 Function(Pointer<Utf8>);
typedef _CPtrFromPtr = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CPtrNoArgs = Pointer<Utf8> Function();
typedef _CPtrFromLL = Pointer<Utf8> Function(Int64);
typedef _CIntNoArgs = Int32 Function();
typedef _CVoidFromPtr = Void Function(Pointer<Utf8>);

class _FfiBackend implements _ApiBackend {
  DynamicLibrary? _lib;

  // Function pointers (lookup при init)
  late final _InitFn _init;
  late final _ShutdownFn _shutdown;
  late final _GetStringFn _getConfigsJson;
  late final _SaveConfigFn _saveConfig;
  late final _DeleteConfigFn _deleteConfig;
  late final _GetStringFn _getSettingsJson;
  late final _SaveSettingsFn _saveSettings;
  late final _GetStringFn _getLogsJson;
  late final _BoolFn _clearLogs;
  late final _GetStringFn _getStatusJson;
  late final _ConnectFn _connect;
  late final _BoolFn _disconnect;
  late final _GetStringFn _checkCoreUpdate;
  late final _BoolFn _updateCore;
  late final _BoolFn _updateCoreAndWait;
  late final _GetStringFn _checkLaLuneUpdate;
  late final _GetStringFn _openLaLuneReleases;
  late final _GetStringFn _getVKTokenState;
  late final _BoolFn _vkLogin;
  late final _BoolFn _deleteVKToken;
  late final _GetStringFn _validateVKToken;
  late final _GetStringFn _runVkAutoApiCalls;
  late final _GetStringFn _pollAutoApiResult;
  late final _FinishVkCallsFn _finishVkCalls;
  late final _GetStringFn _getDeviceId;
  late final _GetStringFn _regenerateDeviceId;
  late final _GetStringFn _getSelectedConfigJson;
  late final _SetSelectedConfigJsonFn _setSelectedConfigJson;
  late final _BoolFn _isCoreDownloading;
  late final _FreeFn _free;

  @override
  Future<void> init() async {
    _lib = _openLaluneLibrary();
    final l = _lib!;

    _init = l.lookupFunction<_CVoid, _CVoid>('lalune_init');
    _shutdown = l.lookupFunction<_CVoid, _CVoid>('lalune_shutdown');

    _getConfigsJson = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_get_configs_json');
    _saveConfig = l.lookupFunction<_CIntFromPtr, _CIntFromPtr>('lalune_save_config');
    _deleteConfig = l.lookupFunction<_CIntFromLL, _CIntFromLL>('lalune_delete_config');

    _getSettingsJson = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_get_settings_json');
    _saveSettings = l.lookupFunction<_CIntFromPtr, _CIntFromPtr>('lalune_save_settings');

    _getLogsJson = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_get_logs_json');
    _clearLogs = l.lookupFunction<_CIntNoArgs, _CIntNoArgs>('lalune_clear_logs');
    _getStatusJson = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_get_status_json');

    _connect = l.lookupFunction<_CIntFromLL, _CIntFromLL>('lalune_connect');
    _disconnect = l.lookupFunction<_CIntNoArgs, _CIntNoArgs>('lalune_disconnect');

    _checkCoreUpdate = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_check_core_update');
    _updateCore = l.lookupFunction<_CIntNoArgs, _CIntNoArgs>('lalune_update_core');
    _updateCoreAndWait = l.lookupFunction<_CIntNoArgs, _CIntNoArgs>('lalune_update_core_and_wait');

    _checkLaLuneUpdate = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_check_lalune_update');
    _openLaLuneReleases = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_open_lalune_releases');

    _getVKTokenState = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_get_vk_token_state');
    _vkLogin = l.lookupFunction<_CIntNoArgs, _CIntNoArgs>('lalune_vk_login');
    _deleteVKToken = l.lookupFunction<_CIntNoArgs, _CIntNoArgs>('lalune_delete_vk_token');
    _validateVKToken = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_validate_vk_token');

    _runVkAutoApiCalls = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_run_vk_auto_api_calls');
    _pollAutoApiResult = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_poll_auto_api_result');
    _finishVkCalls = l.lookupFunction<_CIntFromPtr, _CIntFromPtr>('lalune_finish_vk_calls');

    _getDeviceId = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_get_device_id');
    _regenerateDeviceId = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_regenerate_device_id');

    _getSelectedConfigJson = l.lookupFunction<_CPtrNoArgs, _CPtrNoArgs>('lalune_get_selected_config_json');
    _setSelectedConfigJson = l.lookupFunction<_CIntFromPtr, _CIntFromPtr>('lalune_set_selected_config_json');

    _isCoreDownloading = l.lookupFunction<_CIntNoArgs, _CIntNoArgs>('lalune_is_core_downloading');

    _free = l.lookupFunction<_CVoidFromPtr, _CVoidFromPtr>('lalune_free');

    _init();
  }

  DynamicLibrary _openLaluneLibrary() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    if (Platform.isWindows) {
      // Ищем lalune.dll рядом с .exe.
      for (final name in ['lalune.dll', 'liblalune.dll']) {
        final path = p.join(exeDir, name);
        if (File(path).existsSync()) return DynamicLibrary.open(path);
      }
      // Fallback — по имени из PATH.
      return DynamicLibrary.open('lalune.dll');
    }
    // Linux.
    for (final name in ['liblalune.so', 'lalune.so']) {
      final path = p.join(exeDir, name);
      if (File(path).existsSync()) return DynamicLibrary.open(path);
    }
    return DynamicLibrary.open('liblalune.so');
  }

  String _readAndFree(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return '';
    final s = ptr.toDartString();
    _free(ptr);
    return s;
  }

  Pointer<Utf8> _toC(String s) => s.toNativeUtf8();

  @override
  String getConfigsJson() => _readAndFree(_getConfigsJson());
  @override
  bool saveConfig(String link) {
    final p = _toC(link);
    try { return _saveConfig(p) == 1; } finally { malloc.free(p); }
  }
  @override
  bool deleteConfig(int id) => _deleteConfig(id) == 1;

  @override
  String getSettingsJson() => _readAndFree(_getSettingsJson());
  @override
  bool saveSettings(String json) {
    final p = _toC(json);
    try { return _saveSettings(p) == 1; } finally { malloc.free(p); }
  }

  @override
  String getLogsJson() => _readAndFree(_getLogsJson());
  @override
  bool clearLogs() => _clearLogs() == 1;
  @override
  String getStatusJson() => _readAndFree(_getStatusJson());

  @override
  bool connect(int id) => _connect(id) == 1;
  @override
  bool disconnect() => _disconnect() == 1;

  @override
  String checkCoreUpdate() => _readAndFree(_checkCoreUpdate());
  @override
  bool updateCore() => _updateCore() == 1;
  @override
  bool updateCoreAndWait() => _updateCoreAndWait() == 1;

  @override
  String checkLaLuneUpdate() => _readAndFree(_checkLaLuneUpdate());
  @override
  String openLaLuneReleases() => _readAndFree(_openLaLuneReleases());

  @override
  String getVKTokenState() => _readAndFree(_getVKTokenState());
  @override
  bool vkLogin() => _vkLogin() == 1;
  @override
  bool deleteVKToken() => _deleteVKToken() == 1;
  @override
  String validateVKToken() => _readAndFree(_validateVKToken());

  @override
  String runVkAutoApiCalls() => _readAndFree(_runVkAutoApiCalls());
  @override
  String pollAutoApiResult() => _readAndFree(_pollAutoApiResult());
  @override
  bool finishVkCalls(String callIdsJson) {
    final p = _toC(callIdsJson);
    try { return _finishVkCalls(p) == 1; } finally { malloc.free(p); }
  }

  @override
  String getDeviceId() => _readAndFree(_getDeviceId());
  @override
  String regenerateDeviceId() => _readAndFree(_regenerateDeviceId());

  @override
  String getSelectedConfigJson() => _readAndFree(_getSelectedConfigJson());
  @override
  bool setSelectedConfigJson(String json) {
    final p = _toC(json);
    try { return _setSelectedConfigJson(p) == 1; } finally { malloc.free(p); }
  }

  @override
  bool isCoreDownloading() => _isCoreDownloading() == 1;

  void shutdown() {
    try { _shutdown(); } catch (_) {}
  }
}

// FFI typedefs.
typedef _InitFn = void Function();
typedef _ShutdownFn = void Function();
typedef _GetStringFn = Pointer<Utf8> Function();
typedef _SaveConfigFn = int Function(Pointer<Utf8>);
typedef _DeleteConfigFn = int Function(int);
typedef _SaveSettingsFn = int Function(Pointer<Utf8>);
typedef _BoolFn = int Function();
typedef _ConnectFn = int Function(int);
typedef _FinishVkCallsFn = int Function(Pointer<Utf8>);
typedef _SetSelectedConfigJsonFn = int Function(Pointer<Utf8>);
typedef _FreeFn = void Function(Pointer<Utf8>);

// ------------------------------------------------------------
//  Android / iOS: MethodChannel
// ------------------------------------------------------------

class _MethodChannelBackend implements _ApiBackend {
  static const _channel = MethodChannel('com.lalune.app/bridge');

  @override
  Future<void> init() async {
    // Ничего не делаем — канал живёт на стороне нативной платформы.
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  @override
  String getConfigsJson() => '[]';
  // На Android/iOS часть методов синхронна (getConfigs, getSettings и т.д.),
  // но через MethodChannel все вызовы асинхронны. Поэтому для UI мы работаем
  // через кэш в Dart: первый вызов init() подтягивает актуальные данные.

  // Синхронные геттеры читают локальный кэш, который обновляется из init().
  static String _cachedConfigs = '[]';
  static String _cachedSettings = '{}';
  static String _cachedLogs = '[]';
  static String _cachedStatus = '{"connected":false}';
  static String _cachedVkState = '{"hasToken":false,"fetcherOk":false,"fetching":false,"message":"","progress":0}';
  static String _cachedSelectedConfig = '{}';

  Future<void> refreshAll() async {
    _cachedConfigs = await _invoke<String>('getConfigs') ?? '[]';
    _cachedSettings = await _invoke<String>('getSettings') ?? '{}';
    _cachedLogs = await _invoke<String>('getLogs') ?? '[]';
    _cachedStatus = await _invoke<String>('getStatus') ?? '{"connected":false}';
    _cachedVkState = await _invoke<String>('validateVKToken') ?? _cachedVkState;
    _cachedSelectedConfig = await _invoke<String>('getSelectedConfigJson') ?? '{}';
  }

  @override
  String getConfigsJson() => _cachedConfigs;
  @override
  bool saveConfig(String link) {
    _invoke('saveConfig', {'link': link});
    return true;
  }
  @override
  bool deleteConfig(int id) {
    _invoke('deleteConfig', {'id': id});
    return true;
  }
  @override
  String getSettingsJson() => _cachedSettings;
  @override
  bool saveSettings(String json) {
    _invoke('saveSettings', {'settings': json});
    return true;
  }
  @override
  String getLogsJson() => _cachedLogs;
  @override
  bool clearLogs() {
    _invoke('clearLogs');
    return true;
  }
  @override
  String getStatusJson() => _cachedStatus;
  @override
  bool connect(int id) {
    _invoke('connect', {'configId': id});
    return true;
  }
  @override
  bool disconnect() {
    _invoke('disconnect');
    return true;
  }
  @override
  String checkCoreUpdate() => '{"update":false,"version":""}';
  @override
  bool updateCore() {
    _invoke('updateCore');
    return true;
  }
  @override
  bool updateCoreAndWait() => true;
  @override
  String checkLaLuneUpdate() => '{"update":false,"version":"0.5.0"}';
  @override
  String openLaLuneReleases() {
    _invoke('openLaLuneReleases');
    return '';
  }
  @override
  String getVKTokenState() => _cachedVkState;
  @override
  bool vkLogin() {
    _invoke('vkLogin');
    return true;
  }
  @override
  bool deleteVKToken() {
    _invoke('deleteVKToken');
    return true;
  }
  @override
  String validateVKToken() => _cachedVkState;
  @override
  String runVkAutoApiCalls() {
    _invoke('runVkAutoApiCalls');
    return '{"pending":true}';
  }
  @override
  String pollAutoApiResult() => '{"pending":false}';
  @override
  bool finishVkCalls(String callIdsJson) {
    _invoke('finishVkCalls', {'callIds': callIdsJson});
    return true;
  }
  @override
  String getDeviceId() {
    _invoke('getDeviceId');
    return '';
  }
  @override
  String regenerateDeviceId() {
    _invoke('regenerateDeviceId');
    return '';
  }
  @override
  String getSelectedConfigJson() => _cachedSelectedConfig;
  @override
  bool setSelectedConfigJson(String json) {
    _cachedSelectedConfig = json;
    _invoke('setSelectedConfigJson', {'json': json});
    return true;
  }
  @override
  bool isCoreDownloading() => false;
}

// ============================================================
//  Публичный фасад
// ============================================================

class Api {
  static _ApiBackend? _backend;
  static bool _initialized = false;

  /// Вызывается один раз при старте приложения (в main()).
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (Platform.isAndroid || Platform.isIOS) {
      final b = _MethodChannelBackend();
      _backend = b;
      await b.init();
      await b.refreshAll();
      // Периодический рефреш кэша из нативной стороны.
      Timer.periodic(const Duration(milliseconds: 1500), (_) {
        b.refreshAll();
      });
    } else {
      final b = _FfiBackend();
      _backend = b;
      await b.init();
    }
  }

  static _ApiBackend get _b {
    final b = _backend;
    if (b == null) {
      throw StateError('Api.init() не был вызван');
    }
    return b;
  }

  // --- Configs ---

  static List<ConfigItem> getConfigs() {
    try {
      final arr = jsonDecode(_b.getConfigsJson()) as List;
      return arr.map((e) => ConfigItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static bool saveConfig(String link) => _b.saveConfig(link);
  static bool deleteConfig(int id) => _b.deleteConfig(id);

  // --- Settings ---

  static Settings getSettings() {
    try { return Settings.fromJson(jsonDecode(_b.getSettingsJson()) as Map<String, dynamic>); }
    catch (_) { return Settings(); }
  }

  static bool saveSettings(Settings s) => _b.saveSettings(jsonEncode(s.toJson()));

  // --- Logs / Status ---

  static List<String> getLogs() {
    try {
      final arr = jsonDecode(_b.getLogsJson()) as List;
      return arr.map((e) => e.toString()).toList();
    } catch (_) { return []; }
  }

  static bool clearLogs() => _b.clearLogs();

  static bool isConnected() {
    try {
      final j = jsonDecode(_b.getStatusJson()) as Map<String, dynamic>;
      return (j['connected'] ?? false) as bool;
    } catch (_) { return false; }
  }

  // --- Connect ---

  static bool connect(int id) => _b.connect(id);
  static bool disconnect() => _b.disconnect();

  // --- Core update ---

  static UpdateInfo checkCoreUpdate() {
    try { return UpdateInfo.fromJsonString(_b.checkCoreUpdate()); }
    catch (_) { return UpdateInfo.empty; }
  }
  static bool updateCore() => _b.updateCore();
  static bool updateCoreAndWait() => _b.updateCoreAndWait();

  // --- LaLune update ---

  static UpdateInfo checkLaLuneUpdate() {
    try { return UpdateInfo.fromJsonString(_b.checkLaLuneUpdate()); }
    catch (_) { return UpdateInfo.empty; }
  }
  static bool openLaLuneReleases() {
    _b.openLaLuneReleases();
    return true;
  }

  // --- VK ---

  static VkTokenState getVKTokenState() {
    try { return VkTokenState.fromJsonString(_b.getVKTokenState()); }
    catch (_) { return VkTokenState.empty; }
  }
  static bool vkLogin() => _b.vkLogin();
  static bool deleteVKToken() => _b.deleteVKToken();
  static VkTokenState validateVKToken() {
    try { return VkTokenState.fromJsonString(_b.validateVKToken()); }
    catch (_) { return VkTokenState.empty; }
  }

  // --- Auto API ---

  static AutoApiResult runVkAutoApiCalls() {
    try { return AutoApiResult.fromJsonString(_b.runVkAutoApiCalls()); }
    catch (_) { return const AutoApiResult(error: 'runtime error'); }
  }
  static AutoApiResult pollAutoApiResult() {
    try { return AutoApiResult.fromJsonString(_b.pollAutoApiResult()); }
    catch (_) { return const AutoApiResult(pending: true); }
  }
  static bool finishVkCalls(List<String> callIds) => _b.finishVkCalls(jsonEncode(callIds));

  // --- Device ID ---

  static String getDeviceId() => _b.getDeviceId();
  static String regenerateDeviceId() => _b.regenerateDeviceId();

  // --- Selected config ---

  static String getSelectedConfigJson() => _b.getSelectedConfigJson();
  static bool setSelectedConfigJson(String json) => _b.setSelectedConfigJson(json);

  static ConfigItem? loadSelectedConfigFromJs() {
    try {
      final raw = getSelectedConfigJson();
      if (raw.isEmpty || raw == '{}' || raw == 'null') return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j.isEmpty || (j['id'] == null && j['peer'] == null)) return null;
      return ConfigItem.fromJson(j);
    } catch (_) { return null; }
  }

  // --- Core downloading ---

  static bool isCoreDownloading() => _b.isCoreDownloading();
}
