// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Логи бэкенда + (опционально) ядра.
//
// Источник:
//   * /logs/tail?source=backend — только строки бэкенда
//   * /logs/tail?source=all     — все строки (backend + [CORE] ...)
//
// Переключатель "Показывать логи ядра" живёт в settingsProvider.
//
// ВАЖНО (исправление): showCoreLogs читается через отдельный
// `_showCoreLogsProvider` (Provider<bool>, который watch'ит settingsProvider).
// Это гарантирует, что при переключении toggle и сохранении:
//   1. logsProvider видит новое значение
//   2. _refresh() перечитывает /logs/tail?source=all
//   3. SSE listener фильтрует по актуальному значению
// Плюс периодический опрос каждые 3 сек — на случай race condition.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/sse_client.dart';
import 'providers.dart';
import 'settings_notifier.dart';

/// Отдельный провайдер: true, если пользователь включил показ логов ядра.
final _showCoreLogsProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).data.showCoreLogs;
});

class LogsState {
  final List<String> lines;
  final bool loading;

  const LogsState({this.lines = const [], this.loading = false});

  LogsState copyWith({List<String>? lines, bool? loading}) =>
      LogsState(lines: lines ?? this.lines, loading: loading ?? this.loading);
}

class LogsNotifier extends StateNotifier<LogsState> {
  final Ref _ref;
  Timer? _poll;
  SseClient? _sse;
  StreamSubscription<String>? _baseUrlSub;
  ProviderSubscription<bool>? _showCoreLogsSub;
  int _refreshGeneration = 0;

  LogsNotifier(this._ref) : super(const LogsState()) {
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _startSse();

    // При смене baseUrl — переподключаем SSE и перечитываем.
    final api = _ref.read(apiClientProvider);
    _baseUrlSub = api.baseUrlChanges.listen((_) {
      _sse?.dispose();
      _sse = null;
      state = state.copyWith(lines: const []);
      _startSse();
      _refresh();
    });

    // При смене showCoreLogs — перечитываем с нужным source.
    _showCoreLogsSub = _ref.listen<bool>(
      _showCoreLogsProvider,
      (prev, next) {
        if (prev != next) {
          state = state.copyWith(lines: const []);
          _refresh();
        }
      },
    );
  }

  /// Актуальное значение на каждый запрос.
  bool get _showCoreLogs => _ref.read(_showCoreLogsProvider);

  void _startSse() {
    final api = _ref.read(apiClientProvider);
    _sse = SseClient(
      uriProvider: () => Uri(
        scheme: 'http',
        host: api.host,
        port: api.port,
        path: '/events',
      ),
      baseUrlChanges: api.baseUrlChanges,
    );
    _sse!.stream.listen((ev) {
      if (ev.type == 'log') {
        final line = ev.data['line'] as String? ?? '';
        if (line.isEmpty) return;
        // Читаем каждый раз — не кэшируем.
        if (!_showCoreLogs && _isCoreLog(line)) return;
        // Avoid duplicate SSE entries if the same line is already in the API tail.
        if (state.lines.isNotEmpty && state.lines.last == line) return;
        final next = [...state.lines, line];
        if (next.length > 500) next.removeRange(0, next.length - 500);
        state = state.copyWith(lines: next);
      }
    });
    _sse!.connect();
  }

  bool _isCoreLog(String line) {
    // Logs can have several prefixes, e.g. [LUA] [CORE] ... or [LUA] [SMART-TUNNEL] ...
    final tags = RegExp(r'\[([^\]]+)\]')
        .allMatches(line)
        .map((m) => m.group(1)!.toUpperCase());
    return tags.any((tag) =>
        tag == 'CORE' ||
        tag == 'CSQTT' ||
        tag == 'PAPERFLUX' ||
        tag == 'LUA' ||
        tag == 'SMART-TUNNEL' ||
        tag == 'WINTUN');
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    final api = _ref.read(apiClientProvider);
    // Read the current toggle for each request. Ignore older responses that
    // finish after a newer request (common when the toggle changes mid-flight).
    final source = _showCoreLogs ? 'all' : 'backend';
    try {
      final list = await api.getJsonList('/logs/tail', query: {
        'lines': '300',
        'source': source,
      });
      if (generation != _refreshGeneration) return;
      final fetched = list.map((e) => e.toString()).toList();
      state = state.copyWith(lines: fetched);
    } catch (_) {}
  }

  Future<void> clear() async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.deleteJson('/logs');
      state = state.copyWith(lines: []);
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _sse?.dispose();
    _baseUrlSub?.cancel();
    _showCoreLogsSub?.close();
    super.dispose();
  }
}

final logsProvider = StateNotifierProvider<LogsNotifier, LogsState>((ref) {
  return LogsNotifier(ref);
});
