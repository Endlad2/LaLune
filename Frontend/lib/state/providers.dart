// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Riverpod-провайдеры. Один ApiClient на всё приложение, плюс
// отдельные провайдеры для каждой области данных.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';

/// Единственный экземпляр ApiClient.
final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient();
});

/// Простой FutureProvider для /ping — используется в splash/переподключении.
final pingProvider = FutureProvider<bool>((ref) async {
  final api = ref.watch(apiClientProvider);
  return api.ping();
});
