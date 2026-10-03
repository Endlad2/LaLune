// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Backend watchdog: каждые 3 секунды проверяем /ping. Если API не
// отвечает — на Android/iOS дёргаем MethodChannel, чтобы runner
// перезапустил Backend. На Desktop — просто помечаем состояние
// (там runner сам поднимает процесс и следит за ним).

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'state/providers.dart';

enum BackendStatus { unknown, alive, dead }

class BackendWatchdog extends StateNotifier<BackendStatus> {
  final Ref _ref;
  Timer? _timer;
  final MethodChannel _channel =
      const MethodChannel('com.lalune/native');

  BackendWatchdog(this._ref) : super(BackendStatus.unknown) {
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  Future<void> _tick() async {
    final api = _ref.read(apiClientProvider);
    final alive = await api.ping();
    state = alive ? BackendStatus.alive : BackendStatus.dead;

    if (!alive) {
      await _tryRestart();
    }
  }

  Future<void> _tryRestart() async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _channel.invokeMethod('restartBackend');
    } catch (_) {
      // Native-канал недоступен (например, на десктопе) — игнорируем.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final backendWatchdogProvider =
    StateNotifierProvider<BackendWatchdog, BackendStatus>((ref) {
  return BackendWatchdog(ref);
});

/// Утилита для проверки «жив ли API прямо сейчас».
Future<bool> isBackendAlive(ApiClient api) => api.ping();
