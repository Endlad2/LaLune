// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class ConfigItem {
  final int id;
  final String protocol; // "CSQTT" | "PaperFlux" | "FreeTurn"
  final String peer;
  final String password;
  final String hashes;
  final String profileId;
  final String profileToken;
  final String clientIp;
  final String transport;
  final String url;
  final String urls;
  final String volgaUrl;
  final String relayUrl;
  final String relayToken;
  final String maxToken;
  final String maxUid;
  final String server;
  final String name;
  final String rawLink;

  ConfigItem({
    required this.id,
    required this.protocol,
    this.peer = '',
    this.password = '',
    this.hashes = '',
    this.profileId = '',
    this.profileToken = '',
    this.clientIp = '',
    this.transport = '',
    this.url = '',
    this.urls = '',
    this.volgaUrl = '',
    this.relayUrl = '',
    this.relayToken = '',
    this.maxToken = '',
    this.maxUid = '',
    this.server = '',
    this.name = '',
    this.rawLink = '',
  });

  bool get isPaperFlux => protocol.toLowerCase() == 'paperflux';
  bool get isFreeTurn => protocol.toLowerCase() == 'freeturn';

  factory ConfigItem.fromJson(Map<String, dynamic> j) => ConfigItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        protocol: (j['protocol'] ?? 'CSQTT') as String,
        peer: (j['peer'] ?? '') as String,
        password: (j['password'] ?? '') as String,
        hashes: (j['hashes'] ?? '') as String,
        profileId: (j['profileId'] ?? '') as String,
        profileToken: (j['profileToken'] ?? '') as String,
        clientIp: (j['clientIp'] ?? '') as String,
        transport: (j['transport'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        urls: (j['urls'] ?? '') as String,
        volgaUrl: (j['volgaUrl'] ?? '') as String,
        relayUrl: (j['relayUrl'] ?? '') as String,
        relayToken: (j['relayToken'] ?? '') as String,
        maxToken: (j['maxToken'] ?? '') as String,
        maxUid: (j['maxUid'] ?? '') as String,
        server: (j['server'] ?? '') as String,
        name: (j['name'] ?? j['peer'] ?? j['server'] ?? '') as String,
        rawLink: (j['rawLink'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'protocol': protocol,
        'peer': peer,
        'password': password,
        'hashes': hashes,
        'profileId': profileId,
        'profileToken': profileToken,
        'clientIp': clientIp,
        'transport': transport,
        'url': url,
        'urls': urls,
        'volgaUrl': volgaUrl,
        'relayUrl': relayUrl,
        'relayToken': relayToken,
        'maxToken': maxToken,
        'maxUid': maxUid,
        'server': server,
        'name': name,
        'rawLink': rawLink,
      };

  String get displayName =>
      name.isNotEmpty ? name : (peer.isNotEmpty ? peer : server);
}
