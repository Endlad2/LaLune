// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

const int kDefaultWorkers = 9;
const int kMinWorkers = 1;
const int kMaxWorkers = 127;
const int kDefaultAutoApiWorkers = 9;
const int kMinAutoApiWorkers = 9;
const int kMaxAutoApiWorkers = 27;

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
  final bool showCoreLogs;   // ← новое

  Settings({
    this.peer = '',
    this.vkHashes = '',
    this.vkJsToken = '',
    this.workers = kDefaultWorkers,
    this.autoApiWorkers = kDefaultAutoApiWorkers,
    this.password = '',
    this.obfs = 'video',
    this.fingerprint = 'firefox',
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
    this.showCoreLogs = false,
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
      obfs: (j['obfs'] ?? 'video') as String,
      fingerprint: (j['fingerprint'] ?? 'firefox') as String,
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
      showCoreLogs: (j['showCoreLogs'] ?? false) as bool,
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
        'showCoreLogs': showCoreLogs,
      };

  Settings copyWith({
    String? peer,
    String? vkHashes,
    String? vkJsToken,
    int? workers,
    int? autoApiWorkers,
    String? password,
    String? obfs,
    String? fingerprint,
    String? clientIds,
    String? deviceId,
    String? authMode,
    String? turnTransport,
    String? turnHost,
    String? turnPort,
    String? captchaMode,
    String? vkAuthMode,
    bool? allowHashRedistribution,
    bool? validateVkHashes,
    bool? enableSmartTunnel,
    bool? showCoreLogs,
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
        showCoreLogs: showCoreLogs ?? this.showCoreLogs,
      );
}
