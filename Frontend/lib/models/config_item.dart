// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

  String get displayName => name.isEmpty ? peer : name;
}
