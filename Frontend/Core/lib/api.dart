import 'dart:convert';
import 'dart:js_interop';

@JS('window.api.GetConfigsJson') external String _getConfigsJson();
@JS('window.api.SaveConfig') external bool _saveConfig(String link);
@JS('window.api.DeleteConfig') external bool _deleteConfig(num id);
@JS('window.api.GetSettingsJson') external String _getSettingsJson();
@JS('window.api.SaveSettings') external bool _saveSettings(String json);
@JS('window.api.GetLogsJson') external String _getLogsJson();
@JS('window.api.ClearLogs') external bool _clearLogs();
@JS('window.api.GetStatusJson') external String _getStatusJson();
@JS('window.api.Connect') external bool _connect(num configId);
@JS('window.api.Disconnect') external bool _disconnect();
@JS('window.api.CheckCoreUpdate') external String _checkCoreUpdate();
@JS('window.api.UpdateCore') external bool _updateCore();
@JS('window.api.UpdateCoreAndWait') external bool _updateCoreAndWait();
@JS('window.api.CheckLaLuneUpdate') external String _checkLaLuneUpdate();
@JS('window.api.OpenLaLuneReleases') external bool _openLaLuneReleases();
@JS('window.api.GetVKTokenState') external String _getVKTokenState();
@JS('window.api.LoginVK') external bool _loginVK();
@JS('window.api.DeleteVKToken') external bool _deleteVKToken();
@JS('window.api.RunVkAutoApiCalls') external String _runVkAutoApiCalls();
@JS('window.api.PollAutoApiResult') external String _pollAutoApiResult();
@JS('window.api.FinishVkCalls') external bool _finishVkCalls(String callIdsJson);
@JS('window.api.GetDeviceId') external String _getDeviceId();
@JS('window.api.RegenerateDeviceId') external String _regenerateDeviceId();

class ConfigItem {
  final int id;
  final String protocol;
  final String peer;
  final String password;
  final String hashes;
  final String name;

  ConfigItem({required this.id, required this.protocol, required this.peer,
    required this.password, required this.hashes, required this.name});

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
  final String vkJsToken;
  final String password;
  final int workersPerHash;
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

  Settings({
    this.peer = '',
    this.vkHashes = '',
    this.vkJsToken = '',
    this.password = '',
    this.workersPerHash = 9,
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
  });

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    peer: (j['peer'] ?? '') as String,
    vkHashes: (j['vkHashes'] ?? '') as String,
    vkJsToken: (j['vkJsToken'] ?? '') as String,
    password: (j['password'] ?? '') as String,
    workersPerHash: ((j['workersPerHash'] ?? 9) as num).toInt(),
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
  );

  Map<String, dynamic> toJson() => {
    'peer': peer,
    'vkHashes': vkHashes,
    'vkJsToken': vkJsToken,
    'password': password,
    'workersPerHash': workersPerHash,
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
  };

  Settings copyWith({
    String? peer, String? vkHashes, String? vkJsToken, String? password,
    int? workersPerHash, String? obfs, String? fingerprint, String? clientIds,
    String? deviceId, String? authMode, String? turnTransport,
    String? turnHost, String? turnPort, String? captchaMode,
    String? vkAuthMode, bool? allowHashRedistribution, bool? validateVkHashes,
  }) => Settings(
    peer: peer ?? this.peer,
    vkHashes: vkHashes ?? this.vkHashes,
    vkJsToken: vkJsToken ?? this.vkJsToken,
    password: password ?? this.password,
    workersPerHash: workersPerHash ?? this.workersPerHash,
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

class Api {
  static void init() {}

  static List<ConfigItem> getConfigs() {
    try {
      final arr = jsonDecode(_getConfigsJson()) as List;
      return arr.map((e) => ConfigItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static bool saveConfig(String link) { try { return _saveConfig(link); } catch (_) { return false; } }
  static bool deleteConfig(int id) { try { return _deleteConfig(id); } catch (_) { return false; } }

  static Settings getSettings() {
    try { return Settings.fromJson(jsonDecode(_getSettingsJson()) as Map<String, dynamic>); }
    catch (_) { return Settings(); }
  }

  static bool saveSettings(Settings s) {
    try { return _saveSettings(jsonEncode(s.toJson())); } catch (_) { return false; }
  }

  static List<String> getLogs() {
    try {
      final arr = jsonDecode(_getLogsJson()) as List;
      return arr.map((e) => e.toString()).toList();
    } catch (_) { return []; }
  }

  static bool clearLogs() { try { return _clearLogs(); } catch (_) { return false; } }

  static bool isConnected() {
    try {
      final j = jsonDecode(_getStatusJson()) as Map<String, dynamic>;
      return (j['connected'] ?? false) as bool;
    } catch (_) { return false; }
  }

  static bool connect(int id) { try { return _connect(id); } catch (_) { return false; } }
  static bool disconnect() { try { return _disconnect(); } catch (_) { return false; } }

  static UpdateInfo checkCoreUpdate() {
    try { return UpdateInfo.fromJsonString(_checkCoreUpdate()); }
    catch (_) { return UpdateInfo.empty; }
  }
  static bool updateCore() { try { return _updateCore(); } catch (_) { return false; } }
  static bool updateCoreAndWait() { try { return _updateCoreAndWait(); } catch (_) { return false; } }

  static UpdateInfo checkLaLuneUpdate() {
    try { return UpdateInfo.fromJsonString(_checkLaLuneUpdate()); }
    catch (_) { return UpdateInfo.empty; }
  }
  static bool openLaLuneReleases() { try { return _openLaLuneReleases(); } catch (_) { return false; } }

  static VkTokenState getVKTokenState() {
    try { return VkTokenState.fromJsonString(_getVKTokenState()); }
    catch (_) { return VkTokenState.empty; }
  }
  static bool loginVK() { try { return _loginVK(); } catch (_) { return false; } }
  static bool deleteVKToken() { try { return _deleteVKToken(); } catch (_) { return false; } }

  static AutoApiResult runVkAutoApiCalls() {
    try { return AutoApiResult.fromJsonString(_runVkAutoApiCalls()); }
    catch (_) { return const AutoApiResult(error: 'js error'); }
  }
  static AutoApiResult pollAutoApiResult() {
    try { return AutoApiResult.fromJsonString(_pollAutoApiResult()); }
    catch (_) { return const AutoApiResult(pending: true); }
  }
  static bool finishVkCalls(List<String> callIds) {
    try { return _finishVkCalls(jsonEncode(callIds)); } catch (_) { return false; }
  }

  static String getDeviceId() { try { return _getDeviceId(); } catch (_) { return ''; } }
  static String regenerateDeviceId() { try { return _regenerateDeviceId(); } catch (_) { return ''; } }
}
