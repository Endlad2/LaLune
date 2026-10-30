// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Сканер OpenWRT в локальной сети.
//
// Для подключения перебирает адреса локальных /24 подсетей и проверяет
// LaLune API на :1062/ping. Для установки тем же способом ищет открытый
// SSH-порт :22. Если локальную подсеть определить не удалось, используются
// типичные 192.168.0.0/24 и 192.168.1.0/24.

import 'dart:async';
import 'dart:io';

import '../api/api_client.dart';
import '../models/router_info.dart';

class RouterScanner {
  /// Найти уже установленный LaLune backend по /ping на порту 1062.
  static Stream<RouterInfo> scan({
    Duration timeout = const Duration(milliseconds: 650),
    int batchSize = 32,
  }) async* {
    final hosts = await _candidateHosts();

    for (var i = 0; i < hosts.length; i += batchSize) {
      final end = (i + batchSize < hosts.length) ? i + batchSize : hosts.length;
      final batch = hosts.sublist(i, end);
      final results = await Future.wait(
        batch.map((host) => checkHost(host, timeout: timeout)),
      );

      for (final info in results) {
        if (info == null) continue;
        final platform = info.platform.toLowerCase();
        if (platform.isEmpty || platform == 'openwrt' || platform == 'linux') {
          yield info;
        }
      }
    }
  }

  /// Найти устройства с открытым SSH-портом 22 — используется установщиком.
  static Stream<String> scanSshHosts({
    Duration timeout = const Duration(milliseconds: 400),
    int batchSize = 40,
  }) async* {
    final hosts = await _candidateHosts();

    for (var i = 0; i < hosts.length; i += batchSize) {
      final end = (i + batchSize < hosts.length) ? i + batchSize : hosts.length;
      final batch = hosts.sublist(i, end);
      final results = await Future.wait(
        batch.map((host) async =>
            (host, await isPortOpen(host, 22, timeout: timeout))),
      );

      for (final result in results) {
        if (result.$2) yield result.$1;
      }
    }
  }

  /// Проверить один IP как LaLune/OpenWRT backend.
  static Future<RouterInfo?> checkHost(
    String host, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final j = await ApiClient.pingHost(host, timeout: timeout);
    if (j == null || j['ok'] != true) return null;
    return RouterInfo(
      ip: host,
      hostname: (j['hostname'] ?? '').toString(),
      platform: (j['platform'] ?? '').toString(),
      version: (j['version'] ?? '').toString(),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// TCP-проверка порта без попытки аутентификации.
  static Future<bool> isPortOpen(
    String host,
    int port, {
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<List<String>> _candidateHosts() async {
    final prefixes = <String>{};

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          if (!_isPrivateIpv4(ip)) continue;
          final parts = ip.split('.');
          if (parts.length != 4) continue;
          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
          // Обычно одного-двух LAN-интерфейсов достаточно; не даём VPN/TUN
          // интерфейсам раздувать скан до тысяч адресов.
          if (prefixes.length >= 4) break;
        }
        if (prefixes.length >= 4) break;
      }
    } catch (_) {}

    if (prefixes.isEmpty) {
      prefixes.addAll(const ['192.168.0', '192.168.1']);
    }

    final hosts = <String>[];
    for (final prefix in prefixes) {
      for (var i = 1; i <= 254; i++) {
        hosts.add('$prefix.$i');
      }
    }
    return hosts;
  }

  static bool _isPrivateIpv4(String ip) {
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }
}
