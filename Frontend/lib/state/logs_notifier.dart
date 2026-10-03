// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/sse_client.dart';
import 'providers.dart';

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

  LogsNotifier(this._ref) : super(const LogsState()) {
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _startSse();
  }

  void _startSse() {
    _sse = SseClient();
    _sse!.stream.listen((ev) {
      if (ev.type == 'log') {
        final line = ev.data['line'] as String? ?? '';
        if (line.isEmpty) return;
        final next = [...state.lines, line];
        if (next.length > 500) next.removeRange(0, next.length - 500);
        state = state.copyWith(lines: next);
      }
    });
    _sse!.connect();
  }

  Future<void> _refresh() async {
    final api = _ref.read(apiClientProvider);
    try {
      final list = await api.getJsonList('/logs/tail', query: {'lines': '300'});
      state = state.copyWith(
        lines: list.map((e) => e.toString()).toList(),
      );
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
    super.dispose();
  }
}

final logsProvider = StateNotifierProvider<LogsNotifier, LogsState>((ref) {
  return LogsNotifier(ref);
});
