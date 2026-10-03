// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/config_item.dart';
import 'providers.dart';

class ConfigsState {
  final List<ConfigItem> items;
  final int? selectedId;
  final bool loading;
  final String? error;

  const ConfigsState({
    this.items = const [],
    this.selectedId,
    this.loading = false,
    this.error,
  });

  ConfigsState copyWith({
    List<ConfigItem>? items,
    int? selectedId,
    bool clearSelected = false,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      ConfigsState(
        items: items ?? this.items,
        selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );

  ConfigItem? get selected {
    if (selectedId == null) return null;
    for (final c in items) {
      if (c.id == selectedId) return c;
    }
    return null;
  }
}

class ConfigsNotifier extends StateNotifier<ConfigsState> {
  final Ref _ref;

  ConfigsNotifier(this._ref) : super(const ConfigsState());

  Future<void> reload() async {
    state = state.copyWith(loading: true, clearError: true);
    final api = _ref.read(apiClientProvider);
    try {
      final list = await api.getJsonList('/configs');
      final items = list
          .map((e) => ConfigItem.fromJson(e as Map<String, dynamic>))
          .toList();

      int? newSelected = state.selectedId;
      if (newSelected == null || !items.any((c) => c.id == newSelected)) {
        newSelected = items.isNotEmpty ? items.first.id : null;
        if (newSelected != null) {
          await _selectOnBackend(newSelected);
        }
      }

      state = state.copyWith(
        items: items,
        selectedId: newSelected,
        loading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> select(int id) async {
    state = state.copyWith(selectedId: id);
    await _selectOnBackend(id);
  }

  Future<void> _selectOnBackend(int? id) async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.putJson(
          '/configs/selected', id == null ? {} : {'id': id});
    } catch (_) {}
  }

  Future<bool> add(String link, String protocol) async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.postJson('/configs', {'link': link, 'protocol': protocol});
      await reload();
      return true;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return false;
    }
  }

  Future<bool> delete(int id) async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.deleteJson('/configs/$id');
      if (state.selectedId == id) {
        await _selectOnBackend(null);
      }
      await reload();
      return true;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return false;
    }
  }
}

final configsProvider =
    StateNotifierProvider<ConfigsNotifier, ConfigsState>((ref) {
  return ConfigsNotifier(ref);
});
