// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:convert';

class RouterInfo {
  final String ip;
  final String hostname;
  final String platform; // "openwrt" | "desktop" | "mobile" | ...
  final String version;
  final int addedAt; // ms since epoch

  RouterInfo({
    required this.ip,
    this.hostname = '',
    this.platform = '',
    this.version = '',
    this.addedAt = 0,
  });

  factory RouterInfo.fromJson(Map<String, dynamic> j) => RouterInfo(
        ip: (j['ip'] ?? '') as String,
        hostname: (j['hostname'] ?? '') as String,
        platform: (j['platform'] ?? '') as String,
        version: (j['version'] ?? '') as String,
        addedAt: ((j['addedAt'] ?? 0) as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'hostname': hostname,
        'platform': platform,
        'version': version,
        'addedAt': addedAt,
      };

  String get displayName =>
      hostname.isNotEmpty ? hostname : (ip.isNotEmpty ? ip : 'Router');
}
