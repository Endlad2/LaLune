import 'dart:convert';
import 'dart:js_interop';

@JS('window.api.GetConfigsJson') external String _getConfigsJson();
@JS('window.api.SaveConfig') external bool _saveConfig(String link, String protocol);
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
@JS('window.api.VkLogin') external bool _vkLogin();
@JS('window.api.DeleteVKToken') external bool _deleteVKToken();
@JS('window.api.ValidateVKToken') external String _validateVKToken();
@JS('window.api.RunVkAutoApiCalls') external String _runVkAutoApiCalls();
@JS('window.api.PollAutoApiResult') external String _pollAutoApiResult();
@JS('window.api.FinishVkCalls') external bool _finishVkCalls(String callIdsJson);
@JS('window.api.GetDeviceId') external String _getDeviceId();
@JS('window.api.RegenerateDeviceId') external String _regenerateDeviceId();
@JS('window.api.SetSelectedConfigJson') external bool _setSelectedConfigJson(String json);
@JS('window.api.GetSelectedConfigJson') external String _getSelectedConfigJson();
@JS('window.api.IsCoreDownloading') external bool _isCoreDownloading();

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
    try {
      if (cfg == null) {
        _setSelectedConfigJson('{}');
      } else {
        _setSelectedConfigJson(jsonEncode(cfg.toJson()));
      }
    } catch (_) {}
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

  /// Экспериментальные функции.
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

class Api {
  static void init() {}

  static List<ConfigItem> getConfigs() {
    try {
      final arr = jsonDecode(_getConfigsJson()) as List;
      return arr.map((e) => ConfigItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static bool saveConfig(String link, [String protocol = 'CSQTT']) { try { return _saveConfig(link, protocol); } catch (_) { return false; } }
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

  static bool vkLogin() { try { return _vkLogin(); } catch (_) { return false; } }

  static bool deleteVKToken() { try { return _deleteVKToken(); } catch (_) { return false; } }

  static VkTokenState validateVKToken() {
    try { return VkTokenState.fromJsonString(_validateVKToken()); }
    catch (_) { return VkTokenState.empty; }
  }

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

  static bool isCoreDownloading() {
    try { return _isCoreDownloading(); } catch (_) { return false; }
  }

  static ConfigItem? loadSelectedConfigFromJs() {
    try {
      final raw = _getSelectedConfigJson();
      if (raw.isEmpty || raw == '{}' || raw == 'null') return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j.isEmpty || (j['id'] == null && j['peer'] == null)) return null;
      return ConfigItem.fromJson(j);
    } catch (_) { return null; }
  }
}
