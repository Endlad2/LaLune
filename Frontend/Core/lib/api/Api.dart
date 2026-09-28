// Api.dart — unified LaLune API for native platforms.
//
// Bridges (same method names, different backends):
//   * Linux / Windows  -> C ABI via dart:ffi (lalune_backend cdylib) for TUN,
//                         and MethodChannel "lalune/api" for high-level ops.
//   * Android          -> Java via MethodChannel "lalune/api".
//   * iOS / macOS      -> Swift via MethodChannel "lalune/api".
//
// TUN device lives in LaLune/Backend (Rust). All high-level operations
// (configs, settings, logs, VK token, updates, deploy) are handled by the
// platform side through MethodChannel.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
//  C ABI signatures for the TUN backend (see Backend/src/lib.rs)
// ---------------------------------------------------------------------------
typedef _CreateC = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Int);
typedef _CreateDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int);
typedef _DestroyC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DestroyDart = void Function(ffi.Pointer<ffi.Void>);
typedef _ReadC = ffi.IntPtr Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr);
typedef _ReadDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef _WriteC = ffi.IntPtr Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr);
typedef _WriteDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef _VersionC = ffi.Pointer<ffi.Char> Function();
typedef _VersionDart = ffi.Pointer<ffi.Char> Function();

// ---------------------------------------------------------------------------
//  Constants
// ---------------------------------------------------------------------------
const int kDefaultWorkers = 9;
const int kMinWorkers = 1;
const int kMaxWorkers = 127;
const int kDefaultAutoApiWorkers = 9;
const int kMinAutoApiWorkers = 9;
const int kMaxAutoApiWorkers = 27;

// ---------------------------------------------------------------------------
//  Models
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
        hashes:
            (j['hashes'] as List?)?.map((e) => e.toString()).toList() ?? [],
        callIds:
            (j['callIds'] as List?)?.map((e) => e.toString()).toList() ?? [],
        error: (j['error'] ?? '') as String,
      );
    } catch (_) {
      return const AutoApiResult(error: 'parse error');
    }
  }
}

/// Currently selected config, mirrored to the native side so the backend
/// and settings page can read it.
class SelectedConfig {
  static ConfigItem? _current;
  static ConfigItem? get current => _current;

  static void set(ConfigItem? cfg) {
    _current = cfg;
    try {
      if (cfg == null) {
        _channel.invokeMethod('SetSelectedConfigJson', {'json': '{}'});
      } else {
        _channel
            .invokeMethod('SetSelectedConfigJson', {'json': jsonEncode(cfg.toJson())});
      }
    } catch (_) {}
  }

  static void clear() => set(null);
}

// ---------------------------------------------------------------------------
//  TunResult
// ---------------------------------------------------------------------------
class TunResult {
  final bool ok;
  final String? error;
  const TunResult(this.ok, [this.error]);
}

// ---------------------------------------------------------------------------
//  Api
// ---------------------------------------------------------------------------

class Api {
  Api._();

  static const MethodChannel _channel = MethodChannel('lalune/api');

  static void init() {}

  // ---- TUN (native FFI on desktop, MethodChannel on mobile) --------------

  static ffi.DynamicLibrary? _lib;
  static ffi.DynamicLibrary _nativeLib() {
    _lib ??= _openNative();
    return _lib!;
  }

  static ffi.DynamicLibrary _openNative() {
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('lalune_backend.dll');
    }
    if (Platform.isLinux) {
      return ffi.DynamicLibrary.open('liblalune_backend.so');
    }
    if (Platform.isMacOS) {
      return ffi.DynamicLibrary.open('liblalune_backend.dylib');
    }
    throw UnsupportedError('FFI bridge unsupported on this platform');
  }

  static ffi.Pointer<ffi.Void>? _tunHandle;

  static Future<TunResult> tunCreate({
    String name = '',
    String address = '',
    int mtu = 0,
  }) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final r = await _channel.invokeMethod<String>('tunCreate', {
          'name': name,
          'address': address,
          'mtu': mtu,
        });
        return TunResult(r != null, r);
      }
      final lib = _nativeLib();
      final create =
          lib.lookupFunction<_CreateC, _CreateDart>('lalune_tun_create');
      final n =
          name.isEmpty ? ffi.nullptr : name.toNativeUtf8().cast<ffi.Char>();
      final a = address.isEmpty
          ? ffi.nullptr
          : address.toNativeUtf8().cast<ffi.Char>();
      final h = create(n, a, mtu);
      if (h == ffi.nullptr) {
        return const TunResult(false, 'tun_create returned NULL');
      }
      _tunHandle = h;
      return const TunResult(true);
    } catch (e) {
      return TunResult(false, e.toString());
    }
  }

  static Future<void> tunDestroy() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _channel.invokeMethod('tunDestroy');
      return;
    }
    final h = _tunHandle;
    if (h == null) return;
    final lib = _nativeLib();
    final destroy =
        lib.lookupFunction<_DestroyC, _DestroyDart>('lalune_tun_destroy');
    destroy(h);
    _tunHandle = null;
  }

  static Future<Uint8List?> tunRead(int len) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return _channel.invokeMethod<Uint8List>('tunRead', {'len': len});
    }
    final h = _tunHandle;
    if (h == null) return null;
    final lib = _nativeLib();
    final read = lib.lookupFunction<_ReadC, _ReadDart>('lalune_tun_read');
    final buf = calloc<ffi.Uint8>(len);
    try {
      final n = read(h, buf, len);
      if (n <= 0) return null;
      return Uint8List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  static Future<int> tunWrite(Uint8List data) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final r = await _channel.invokeMethod<int>('tunWrite', {'data': data});
      return r ?? -1;
    }
    final h = _tunHandle;
    if (h == null) return -1;
    final lib = _nativeLib();
    final write = lib.lookupFunction<_WriteC, _WriteDart>('lalune_tun_write');
    final buf = calloc<ffi.Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      return write(h, buf, data.length);
    } finally {
      calloc.free(buf);
    }
  }

  static Future<String> version() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final v = await _channel.invokeMethod<String>('version');
      return v ?? 'unknown';
    }
    final lib = _nativeLib();
    final ver = lib.lookupFunction<_VersionC, _VersionDart>('lalune_version');
    return ver().cast<Utf8>().toDartString();
  }

  // ---- High-level API (all via MethodChannel "lalune/api") ---------------
  //
  // The platform side (Go / Java / Swift) implements every method below.
  // Names match the old JS bridge so UI code stays unchanged.

  // Configs
  static List<ConfigItem> getConfigs() {
    // Sync fallback: we keep a cached list refreshed by `refreshConfigs()`.
    return _configsCache;
  }

  static List<ConfigItem> _configsCache = [];

  static Future<void> refreshConfigs() async {
    try {
      final raw = await _channel.invokeMethod<String>('GetConfigsJson');
      if (raw == null) return;
      final arr = jsonDecode(raw) as List;
      _configsCache = arr
          .map((e) => ConfigItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  static bool saveConfig(String link, [String protocol = 'CSQTT']) {
    _channel.invokeMethod('SaveConfig', {'link': link, 'protocol': protocol});
    return true;
  }

  static bool deleteConfig(int id) {
    _channel.invokeMethod('DeleteConfig', {'id': id});
    return true;
  }

  // Settings
  static Settings _settingsCache = Settings();

  static Settings getSettings() => _settingsCache;

  static Future<void> refreshSettings() async {
    try {
      final raw = await _channel.invokeMethod<String>('GetSettingsJson');
      if (raw == null) return;
      _settingsCache =
          Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  static bool saveSettings(Settings s) {
    _channel
        .invokeMethod('SaveSettings', {'json': jsonEncode(s.toJson())});
    _settingsCache = s;
    return true;
  }

  // Logs
  static List<String> _logsCache = [];
  static List<String> getLogs() => _logsCache;

  static Future<void> refreshLogs() async {
    try {
      final raw = await _channel.invokeMethod<String>('GetLogsJson');
      if (raw == null) return;
      final arr = jsonDecode(raw) as List;
      _logsCache = arr.map((e) => e.toString()).toList();
    } catch (_) {}
  }

  static bool clearLogs() {
    _channel.invokeMethod('ClearLogs');
    _logsCache = [];
    return true;
  }

  // Status / connection
  static bool _connectedCache = false;
  static bool isConnected() => _connectedCache;

  static Future<void> refreshStatus() async {
    try {
      final raw = await _channel.invokeMethod<String>('GetStatusJson');
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _connectedCache = (j['connected'] ?? false) as bool;
    } catch (_) {}
  }

  static bool connect(int id) {
    _channel.invokeMethod('Connect', {'id': id});
    _connectedCache = true;
    return true;
  }

  static bool disconnect() {
    _channel.invokeMethod('Disconnect');
    _connectedCache = false;
    return true;
  }

  // Core updates
  static UpdateInfo _coreUpdateCache = UpdateInfo.empty;
  static UpdateInfo checkCoreUpdate() => _coreUpdateCache;

  static Future<void> refreshCoreUpdate() async {
    try {
      final raw = await _channel.invokeMethod<String>('CheckCoreUpdate');
      if (raw == null) return;
      _coreUpdateCache = UpdateInfo.fromJsonString(raw);
    } catch (_) {}
  }

  static bool updateCore() {
    _channel.invokeMethod('UpdateCore');
    return true;
  }

  static bool updateCoreAndWait() {
    _channel.invokeMethod('UpdateCoreAndWait');
    return true;
  }

  // LaLune updates
  static UpdateInfo _laluneUpdateCache = UpdateInfo.empty;
  static UpdateInfo checkLaLuneUpdate() => _laluneUpdateCache;

  static Future<void> refreshLaLuneUpdate() async {
    try {
      final raw = await _channel.invokeMethod<String>('CheckLaLuneUpdate');
      if (raw == null) return;
      _laluneUpdateCache = UpdateInfo.fromJsonString(raw);
    } catch (_) {}
  }

  static bool openLaLuneReleases() {
    _channel.invokeMethod('OpenLaLuneReleases');
    return true;
  }

  // VK token
  static VkTokenState _vkStateCache = VkTokenState.empty;
  static VkTokenState getVKTokenState() => _vkStateCache;

  static Future<void> refreshVkState() async {
    try {
      final raw = await _channel.invokeMethod<String>('GetVKTokenState');
      if (raw == null) return;
      _vkStateCache = VkTokenState.fromJsonString(raw);
    } catch (_) {}
  }

  static bool vkLogin() {
    _channel.invokeMethod('VkLogin');
    return true;
  }

  static bool deleteVKToken() {
    _channel.invokeMethod('DeleteVKToken');
    _vkStateCache = VkTokenState.empty;
    return true;
  }

  static VkTokenState validateVKToken() {
    _channel.invokeMethod<String>('ValidateVKToken').then((raw) {
      if (raw != null) _vkStateCache = VkTokenState.fromJsonString(raw);
    });
    return _vkStateCache;
  }

  // VK auto API
  static AutoApiResult runVkAutoApiCalls() {
    _channel.invokeMethod<String>('RunVkAutoApiCalls');
    return const AutoApiResult(pending: true);
  }

  static AutoApiResult pollAutoApiResult() {
    return const AutoApiResult(pending: true);
  }

  static bool finishVkCalls(List<String> callIds) {
    _channel.invokeMethod('FinishVkCalls', {'callIds': jsonEncode(callIds)});
    return true;
  }

  // Device ID
  static String _deviceIdCache = '';
  static String getDeviceId() => _deviceIdCache;

  static Future<void> refreshDeviceId() async {
    try {
      final raw = await _channel.invokeMethod<String>('GetDeviceId');
      if (raw != null) _deviceIdCache = raw;
    } catch (_) {}
  }

  static String regenerateDeviceId() {
    _channel.invokeMethod<String>('RegenerateDeviceId').then((raw) {
      if (raw != null) _deviceIdCache = raw;
    });
    return _deviceIdCache;
  }

  // Core download flag
  static bool _coreDownloadingCache = false;
  static bool isCoreDownloading() => _coreDownloadingCache;

  static Future<void> refreshCoreDownloading() async {
    try {
      final raw = await _channel.invokeMethod<bool>('IsCoreDownloading');
      _coreDownloadingCache = raw ?? false;
    } catch (_) {}
  }

  // Deploy
  static String _deployLogCache = '';
  static bool _deployingCache = false;

  static bool deploy(String json) {
    _channel.invokeMethod('DeployProtocol', {'json': json});
    _deployingCache = true;
    return true;
  }

  static String deployLog() => _deployLogCache;
  static bool isDeploying() => _deployingCache;

  static Future<void> refreshDeployState() async {
    try {
      final log = await _channel.invokeMethod<String>('DeployLog');
      if (log != null) _deployLogCache = log;
      final busy = await _channel.invokeMethod<bool>('IsDeploying');
      _deployingCache = busy ?? false;
    } catch (_) {}
  }

  // Selected config
  static ConfigItem? loadSelectedConfigFromJs() {
    return SelectedConfig.current;
  }

  /// Refresh everything at once (call from initState).
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

// Re-export StringList for convenience where needed
typedef Uint8List = List<int>;
