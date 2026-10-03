// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

  SettingsNotifier(this._ref)
      : super(SettingsState(data: Settings()));

  Future<void> reload() async {
    state = state.copyWith(loading: true, clearError: true);
    final api = _ref.read(apiClientProvider);
    try {
      final j = await api.getJson('/settings');
      state = state.copyWith(
        data: Settings.fromJson(j),
        loading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<bool> save(Settings s) async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.putJson('/settings', s.toJson());
      state = state.copyWith(data: s, clearError: true);
      return true;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return false;
    }
  }

  Future<String> regenerateDeviceId() async {
    final api = _ref.read(apiClientProvider);
    try {
      final j = await api.postJson('/device/id/regenerate', {});
      final newId = (j['deviceId'] ?? '') as String;
      state = state.copyWith(data: state.data.copyWith(deviceId: newId));
      return newId;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return '';
    }
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier(ref);
});
