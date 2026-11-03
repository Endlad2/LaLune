// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки. deviceId удалён — новый CSQTT его не использует.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/settings.dart';
import 'providers.dart';

class SettingsState {
  final Settings data;
  final bool loading;
  final String? error;

  const SettingsState({
    required this.data,
    this.loading = false,
    this.error,
  });

  SettingsState copyWith({
    Settings? data,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      SettingsState(
        data: data ?? this.data,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  final Ref _ref;
  StreamSubscription<String>? _baseUrlSub;
  int _requestGeneration = 0;

  SettingsNotifier(this._ref) : super(SettingsState(data: Settings())) {
    // При смене baseUrl (подключение/отключение роутера) — перезагружаем.
    final api = _ref.read(apiClientProvider);
    _baseUrlSub = api.baseUrlChanges.listen((_) {
      reload();
    });
  }

  Future<void> reload() async {
    final generation = ++_requestGeneration;
    state = state.copyWith(loading: true, clearError: true);
    final api = _ref.read(apiClientProvider);
    final baseUrl = api.baseUrl;
    try {
      final j = await api.getJson('/settings');
      if (!_isCurrent(generation, baseUrl)) return;
      state = state.copyWith(
        data: Settings.fromJson(j),
        loading: false,
        clearError: true,
      );
    } catch (e) {
      if (!_isCurrent(generation, baseUrl)) return;
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<bool> save(Settings s) async {
    final generation = ++_requestGeneration;
    final api = _ref.read(apiClientProvider);
    final baseUrl = api.baseUrl;
    try {
      await api.putJson('/settings', s.toJson());
      if (!_isCurrent(generation, baseUrl)) return false;
      final saved = Settings.fromJson(await api.getJson('/settings'));
      if (!_isCurrent(generation, baseUrl)) return false;
      final expected = s.toJson();
      final actual = saved.toJson();
      // Старый backend может ответить ok, отбросив неизвестные поля.
      for (final key in [
        'desktopSocks5Mode',
        'ipRoutingMode',
        'ipRoutingIps',
        'showCoreLogs',
      ]) {
        if (actual[key] != expected[key]) {
          state = state.copyWith(
            data: saved,
            loading: false,
            error:
                'Сохранение не подтверждено: бэкенд вернул другие настройки. '
                'Обновите приложение вместе с бэкендом и повторите сохранение.',
          );
          return false;
        }
      }
      state = state.copyWith(data: saved, loading: false, clearError: true);
      return true;
    } catch (e) {
      if (_isCurrent(generation, baseUrl)) {
        state = state.copyWith(loading: false, error: '$e');
      }
      return false;
    }
  }

  bool _isCurrent(int generation, String baseUrl) =>
      mounted &&
      generation == _requestGeneration &&
      _ref.read(apiClientProvider).baseUrl == baseUrl;

  @override
  void dispose() {
    _baseUrlSub?.cancel();
    super.dispose();
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier(ref);
});
