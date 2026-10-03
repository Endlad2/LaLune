// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Сканер роутеров в локальной сети.
//
// Перебирает 192.168.0.1, 192.168.1.1, ..., 192.168.255.1
// на порту 1062 (endpoint /ping).
//
// Параллельно (батчами по 24), с таймаутом 600 мс на адрес.
// Возвращает RouterInfo для всех, кто ответил с platform="openwrt"
// (или platform пустой — старые версии бэкенда без platform).
//
// Принимает ручной IP — сразу добавляет его в список.

import 'dart:async';

import '../api/api_client.dart';
import '../models/router_info.dart';

class RouterScanner {
  /// Отсканировать диапазон 192.168.X.1 (X = 0..255).
  static Stream<RouterInfo> scan({
    Duration timeout = const Duration(milliseconds: 600),
    int batchSize = 24,
  }) async* {
    final controller = StreamController<RouterInfo>();

    // Список адресов: 192.168.0.1, 192.168.1.1, ...
    final hosts = List<String>.generate(256, (i) => '192.168.$i.1');

    // Параллельно батчами по batchSize.
    for (var i = 0; i < hosts.length; i += batchSize) {
      final batch = hosts.sublist(i, (i + batchSize).clamp(0, hosts.length));
      await Future.wait(batch.map((host) async {
        final j = await ApiClient.pingHost(host, timeout: timeout);
        if (j != null && j['ok'] == true) {
          // Проверяем, что это LaLune-бэкенд (platform=openwrt).
          // Но некоторые роутеры могут иметь старую версию без platform —
          // тогда тоже принимаем, чтобы не блокировать.
          final platform = (j['platform'] ?? '') as String;
          if (platform.isEmpty || platform == 'openwrt' || platform == 'linux') {
            controller.add(RouterInfo(
              ip: host,
              hostname: (j['hostname'] ?? '') as String,
              platform: platform,
              version: (j['version'] ?? '') as String,
              addedAt: DateTime.now().millisecondsSinceEpoch,
            ));
          }
        }
      }));
      // Небольшая задержка между батчами, чтобы не забить сеть.
      await Future.delayed(const Duration(milliseconds: 50));
    }

    await controller.close();
    yield* controller.stream;
  }

  /// Проверить один IP вручную. Возвращает RouterInfo или null.
  static Future<RouterInfo?> checkHost(String host,
      {Duration timeout = const Duration(seconds: 2)}) async {
    final j = await ApiClient.pingHost(host, timeout: timeout);
    if (j == null || j['ok'] != true) return null;
    return RouterInfo(
      ip: host,
      hostname: (j['hostname'] ?? '') as String,
      platform: (j['platform'] ?? '') as String,
      version: (j['version'] ?? '') as String,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
