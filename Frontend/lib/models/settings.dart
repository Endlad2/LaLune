// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки LaLune: CSQTT + PaperFlux + FreeTurn.
// deviceId удалён — новый CSQTT его не использует.

const int kDefaultWorkers = 9;
const int kMinWorkers = 1;
const int kMaxWorkers = 127;
const int kDefaultAutoApiWorkers = 9;
const int kMinAutoApiWorkers = 9;
const int kMaxAutoApiWorkers = 27;

class Settings {
  // CSQTT
  final String peer;
  final String vkHashes;
  final String vkJsToken;
  final int workers;
  final int autoApiWorkers;
  final String password;
  final String obfs;
  final String fingerprint;
  final String clientIds;
  final String authMode;
  final String turnTransport;
  final String turnHost;
  final String turnPort;
  final String captchaMode;
  final String vkAuthMode;
  final bool allowHashRedistribution;
  final bool validateVkHashes;

  // PaperFlux
  final String pfTransport;
  final String pfUrl;
  final String pfUrls;
  final String pfVolgaUrl;
  final String pfMode;
  final String pfSocks5;
  final String pfTcpRecovery;
  final bool pfSession;
  final String pfClientIp;
  final String pfAuthService;
  final String pfIpcSocket;
  final String pfTunFdSock;
  final String pfPacketSock;
  final String pfExitProfiles;
  final String pfExitStats;
  final String pfExitCookies;
  final String pfRelayUrl;
  final String pfRelayToken;
  final int pfRelayUser;
  final String pfRelaySession;
  final String pfMaxToken;
  final String pfMaxUid;

  // FreeTurn
  final String ftProvider;   // vk | direct
  final String ftTransport;  // tcp | udp
  final String ftMode;       // udp | tcp
  final bool   ftBond;       // только для mode=tcp
  final String ftObf;        // none | rtpopus | rtpopus2 | rtpopus3
  final String ftKey;        // hex64
  final int    ftN;          // TURN-потоков
  final int    ftSpc;        // потоков на кеш учёток
  final String ftCid;        // Client ID
  final String ftListen;     // 127.0.0.1:9000
  final String ftDns;        // plain | doh | auto
  final String ftDnss;       // свои UDP/53 DNS через запятую
  final bool   ftMcap;       // ручная captcha
  final String ftKcp;        // сериализованные -kcp-* (только tcp)
  final String ftLink;       // VK-ссылка на звонок (-link)
  final String ftWgConf;     // WireGuard-конфиг (если есть — StartTunnel)

  // Экспериментальное
  final bool enableSmartTunnel;
  final bool showCoreLogs;
  final bool shareVpn;

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
    this.authMode = 'manual',
    this.turnTransport = 'udp',
    this.turnHost = '',
    this.turnPort = '',
    this.captchaMode = 'auto',
    this.vkAuthMode = 'vkcalls',
    this.allowHashRedistribution = false,
    this.validateVkHashes = false,
    this.pfTransport = 'yandex',
    this.pfUrl = '',
    this.pfUrls = '',
    this.pfVolgaUrl = '',
    this.pfMode = 'proxy',
    this.pfSocks5 = '127.0.0.1:1080',
    this.pfTcpRecovery = 'auto',
    this.pfSession = false,
    this.pfClientIp = '10.10.10.2',
    this.pfAuthService = '',
    this.pfIpcSocket = '',
    this.pfTunFdSock = '',
    this.pfPacketSock = '',
    this.pfExitProfiles = '',
    this.pfExitStats = '',
    this.pfExitCookies = '',
    this.pfRelayUrl = '',
    this.pfRelayToken = '',
    this.pfRelayUser = 0,
    this.pfRelaySession = '',
    this.pfMaxToken = '',
    this.pfMaxUid = '',
    this.ftProvider = 'vk',
    this.ftTransport = 'tcp',
    this.ftMode = 'udp',
    this.ftBond = false,
    this.ftObf = 'rtpopus3',
    this.ftKey = '',
    this.ftN = 12,
    this.ftSpc = 12,
    this.ftCid = '',
    this.ftListen = '127.0.0.1:9000',
    this.ftDns = 'auto',
    this.ftDnss = '',
    this.ftMcap = false,
    this.ftKcp = '',
    this.ftLink = '',
    this.ftWgConf = '',
    this.enableSmartTunnel = false,
    this.showCoreLogs = false,
    this.shareVpn = false,
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
      authMode: (j['authMode'] ?? 'manual') as String,
      turnTransport: (j['turnTransport'] ?? 'udp') as String,
      turnHost: (j['turnHost'] ?? '') as String,
      turnPort: (j['turnPort'] ?? '') as String,
      captchaMode: (j['captchaMode'] ?? 'auto') as String,
      vkAuthMode: (j['vkAuthMode'] ?? 'vkcalls') as String,
      allowHashRedistribution: (j['allowHashRedistribution'] ?? false) as bool,
      validateVkHashes: (j['validateVkHashes'] ?? false) as bool,
      pfTransport: (j['pfTransport'] ?? 'yandex') as String,
      pfUrl: (j['pfUrl'] ?? '') as String,
      pfUrls: (j['pfUrls'] ?? '') as String,
      pfVolgaUrl: (j['pfVolgaUrl'] ?? '') as String,
      pfMode: (j['pfMode'] ?? 'proxy') as String,
      pfSocks5: (j['pfSocks5'] ?? '127.0.0.1:1080') as String,
      pfTcpRecovery: (j['pfTcpRecovery'] ?? 'auto') as String,
      pfSession: (j['pfSession'] ?? false) as bool,
      pfClientIp: (j['pfClientIp'] ?? '10.10.10.2') as String,
      pfAuthService: (j['pfAuthService'] ?? '') as String,
      pfIpcSocket: (j['pfIpcSocket'] ?? '') as String,
      pfTunFdSock: (j['pfTunFdSock'] ?? '') as String,
      pfPacketSock: (j['pfPacketSock'] ?? '') as String,
      pfExitProfiles: (j['pfExitProfiles'] ?? '') as String,
      pfExitStats: (j['pfExitStats'] ?? '') as String,
      pfExitCookies: (j['pfExitCookies'] ?? '') as String,
      pfRelayUrl: (j['pfRelayUrl'] ?? '') as String,
      pfRelayToken: (j['pfRelayToken'] ?? '') as String,
      pfRelayUser: ((j['pfRelayUser'] ?? 0) as num).toInt(),
      pfRelaySession: (j['pfRelaySession'] ?? '') as String,
      pfMaxToken: (j['pfMaxToken'] ?? '') as String,
      pfMaxUid: (j['pfMaxUid'] ?? '') as String,
      ftProvider: (j['ftProvider'] ?? 'vk') as String,
      ftTransport: (j['ftTransport'] ?? 'tcp') as String,
      ftMode: (j['ftMode'] ?? 'udp') as String,
      ftBond: (j['ftBond'] ?? false) as bool,
      ftObf: (j['ftObf'] ?? 'rtpopus3') as String,
      ftKey: (j['ftKey'] ?? '') as String,
      ftN: ((j['ftN'] ?? 12) as num).toInt(),
      ftSpc: ((j['ftSpc'] ?? 12) as num).toInt(),
      ftCid: (j['ftCid'] ?? '') as String,
      ftListen: (j['ftListen'] ?? '127.0.0.1:9000') as String,
      ftDns: (j['ftDns'] ?? 'auto') as String,
      ftDnss: (j['ftDnss'] ?? '') as String,
      ftMcap: (j['ftMcap'] ?? false) as bool,
      ftKcp: (j['ftKcp'] ?? '') as String,
      ftLink: (j['ftLink'] ?? '') as String,
      ftWgConf: (j['ftWgConf'] ?? '') as String,
      enableSmartTunnel: (j['enableSmartTunnel'] ?? false) as bool,
      showCoreLogs: (j['showCoreLogs'] ?? false) as bool,
      shareVpn: (j['shareVpn'] ?? false) as bool,
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
        'authMode': authMode,
        'turnTransport': turnTransport,
        'turnHost': turnHost,
        'turnPort': turnPort,
        'captchaMode': captchaMode,
        'vkAuthMode': vkAuthMode,
        'allowHashRedistribution': allowHashRedistribution,
        'validateVkHashes': validateVkHashes,
        'pfTransport': pfTransport,
        'pfUrl': pfUrl,
        'pfUrls': pfUrls,
        'pfVolgaUrl': pfVolgaUrl,
        'pfMode': pfMode,
        'pfSocks5': pfSocks5,
        'pfTcpRecovery': pfTcpRecovery,
        'pfSession': pfSession,
        'pfClientIp': pfClientIp,
        'pfAuthService': pfAuthService,
        'pfIpcSocket': pfIpcSocket,
        'pfTunFdSock': pfTunFdSock,
        'pfPacketSock': pfPacketSock,
        'pfExitProfiles': pfExitProfiles,
        'pfExitStats': pfExitStats,
        'pfExitCookies': pfExitCookies,
        'pfRelayUrl': pfRelayUrl,
        'pfRelayToken': pfRelayToken,
        'pfRelayUser': pfRelayUser,
        'pfRelaySession': pfRelaySession,
        'pfMaxToken': pfMaxToken,
        'pfMaxUid': pfMaxUid,
        'ftProvider': ftProvider,
        'ftTransport': ftTransport,
        'ftMode': ftMode,
        'ftBond': ftBond,
        'ftObf': ftObf,
        'ftKey': ftKey,
        'ftN': ftN,
        'ftSpc': ftSpc,
        'ftCid': ftCid,
        'ftListen': ftListen,
        'ftDns': ftDns,
        'ftDnss': ftDnss,
        'ftMcap': ftMcap,
        'ftKcp': ftKcp,
        'ftLink': ftLink,
        'ftWgConf': ftWgConf,
        'enableSmartTunnel': enableSmartTunnel,
        'showCoreLogs': showCoreLogs,
        'shareVpn': shareVpn,
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
    String? authMode,
    String? turnTransport,
    String? turnHost,
    String? turnPort,
    String? captchaMode,
    String? vkAuthMode,
    bool? allowHashRedistribution,
    bool? validateVkHashes,
    String? pfTransport,
    String? pfUrl,
    String? pfUrls,
    String? pfVolgaUrl,
    String? pfMode,
    String? pfSocks5,
    String? pfTcpRecovery,
    bool? pfSession,
    String? pfClientIp,
    String? pfAuthService,
    String? pfIpcSocket,
    String? pfTunFdSock,
    String? pfPacketSock,
    String? pfExitProfiles,
    String? pfExitStats,
    String? pfExitCookies,
    String? pfRelayUrl,
    String? pfRelayToken,
    int? pfRelayUser,
    String? pfRelaySession,
    String? pfMaxToken,
    String? pfMaxUid,
    String? ftProvider,
    String? ftTransport,
    String? ftMode,
    bool? ftBond,
    String? ftObf,
    String? ftKey,
    int? ftN,
    int? ftSpc,
    String? ftCid,
    String? ftListen,
    String? ftDns,
    String? ftDnss,
    bool? ftMcap,
    String? ftKcp,
    String? ftLink,
    String? ftWgConf,
    bool? enableSmartTunnel,
    bool? showCoreLogs,
    bool? shareVpn,
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
        authMode: authMode ?? this.authMode,
        turnTransport: turnTransport ?? this.turnTransport,
        turnHost: turnHost ?? this.turnHost,
        turnPort: turnPort ?? this.turnPort,
        captchaMode: captchaMode ?? this.captchaMode,
        vkAuthMode: vkAuthMode ?? this.vkAuthMode,
        allowHashRedistribution: allowHashRedistribution ?? this.allowHashRedistribution,
        validateVkHashes: validateVkHashes ?? this.validateVkHashes,
        pfTransport: pfTransport ?? this.pfTransport,
        pfUrl: pfUrl ?? this.pfUrl,
        pfUrls: pfUrls ?? this.pfUrls,
        pfVolgaUrl: pfVolgaUrl ?? this.pfVolgaUrl,
        pfMode: pfMode ?? this.pfMode,
        pfSocks5: pfSocks5 ?? this.pfSocks5,
        pfTcpRecovery: pfTcpRecovery ?? this.pfTcpRecovery,
        pfSession: pfSession ?? this.pfSession,
        pfClientIp: pfClientIp ?? this.pfClientIp,
        pfAuthService: pfAuthService ?? this.pfAuthService,
        pfIpcSocket: pfIpcSocket ?? this.pfIpcSocket,
        pfTunFdSock: pfTunFdSock ?? this.pfTunFdSock,
        pfPacketSock: pfPacketSock ?? this.pfPacketSock,
        pfExitProfiles: pfExitProfiles ?? this.pfExitProfiles,
        pfExitStats: pfExitStats ?? this.pfExitStats,
        pfExitCookies: pfExitCookies ?? this.pfExitCookies,
        pfRelayUrl: pfRelayUrl ?? this.pfRelayUrl,
        pfRelayToken: pfRelayToken ?? this.pfRelayToken,
        pfRelayUser: pfRelayUser ?? this.pfRelayUser,
        pfRelaySession: pfRelaySession ?? this.pfRelaySession,
        pfMaxToken: pfMaxToken ?? this.pfMaxToken,
        pfMaxUid: pfMaxUid ?? this.pfMaxUid,
        ftProvider: ftProvider ?? this.ftProvider,
        ftTransport: ftTransport ?? this.ftTransport,
        ftMode: ftMode ?? this.ftMode,
        ftBond: ftBond ?? this.ftBond,
        ftObf: ftObf ?? this.ftObf,
        ftKey: ftKey ?? this.ftKey,
        ftN: ftN ?? this.ftN,
        ftSpc: ftSpc ?? this.ftSpc,
        ftCid: ftCid ?? this.ftCid,
        ftListen: ftListen ?? this.ftListen,
        ftDns: ftDns ?? this.ftDns,
        ftDnss: ftDnss ?? this.ftDnss,
        ftMcap: ftMcap ?? this.ftMcap,
        ftKcp: ftKcp ?? this.ftKcp,
        ftLink: ftLink ?? this.ftLink,
        ftWgConf: ftWgConf ?? this.ftWgConf,
        enableSmartTunnel: enableSmartTunnel ?? this.enableSmartTunnel,
        showCoreLogs: showCoreLogs ?? this.showCoreLogs,
        shareVpn: shareVpn ?? this.shareVpn,
      );
}
