// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vk_token_state.dart';
import 'providers.dart';

class VkNotifier extends StateNotifier<VkTokenState> {
  final Ref _ref;
  Timer? _poll;

  VkNotifier(this._ref) : super(VkTokenState.empty) {
    _refresh();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final api = _ref.read(apiClientProvider);
    try {
      final j = await api.getJson('/vk/token/state');
      final next = VkTokenState.fromJson(j);
      if (next.hasToken != state.hasToken ||
          next.fetching != state.fetching ||
          next.progress != state.progress ||
          next.message != state.message) {
        state = next;
      }
    } catch (_) {}
  }

  Future<bool> login() async {
    final api = _ref.read(apiClientProvider);
    try {
      // Бэкенд сам открывает WebView (Android/iOS) или запускает
      // Token.ps1/Token.sh (Desktop).
      await api.postJson('/vk/token/login', {});
      state = const VkTokenState(fetching: true, progress: 10,
          message: 'Открываю окно авторизации...');
      return true;
    } catch (e) {
      state = VkTokenState(message: '$e');
      return false;
    }
  }

  Future<bool> deleteToken() async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.deleteJson('/vk/token');
      state = VkTokenState.empty;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

final vkProvider = StateNotifierProvider<VkNotifier, VkTokenState>((ref) {
  return VkNotifier(ref);
});
