// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Управление подключением к OpenWRT-роутеру.
//
// Состояние:
//   * savedRouters    — список сохранённых роутеров (SharedPreferences)
//   * activeRouter    — к какому роутеру мы подключены (null = localhost)
//   * scanning        — идёт ли скан сети
//   * scannedRouters  — найденные при скане (только в памяти)
//
// Логика:
//   connect(router)      — переключает ApiClient.setBaseUrl(router.ip),
//                          сохраняет в SharedPreferences,
//                          шлёт POST /vk/token/submit на роутер с нашим токеном.
//   disconnect()         — ApiClient.resetBaseUrl(),
//                          очищает activeRouter.
//   addManualIp(ip)      — вручную добавить IP (без скана).
//   removeRouter(ip)     — удалить из сохранённых.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/router_info.dart';
import 'providers.dart';
import 'router_scanner.dart';

const String _prefsKey = 'lalune.saved_routers';
const String _prefsActiveKey = 'lalune.active_router';

class RouterState {
  final List<RouterInfo> savedRouters;
  final List<RouterInfo> scannedRouters;
  final RouterInfo? activeRouter;
  final bool scanning;
  final String? error;
  final String? lastConnectedName;

  const RouterState({
    this.savedRouters = const [],
    this.scannedRouters = const [],
    this.activeRouter,
    this.scanning = false,
    this.error,
    this.lastConnectedName,
  });

  bool get isConnected => activeRouter != null;

  RouterState copyWith({
    List<RouterInfo>? savedRouters,
    List<RouterInfo>? scannedRouters,
    RouterInfo? activeRouter,
    bool clearActive = false,
    bool? scanning,
    String? error,
    bool clearError = false,
    String? lastConnectedName,
    bool clearLastConnected = false,
  }) =>
      RouterState(
        savedRouters: savedRouters ?? this.savedRouters,
        scannedRouters: scannedRouters ?? this.scannedRouters,
        activeRouter: clearActive ? null : (activeRouter ?? this.activeRouter),
        scanning: scanning ?? this.scanning,
        error: clearError ? null : (error ?? this.error),
        lastConnectedName: clearLastConnected
            ? null
            : (lastConnectedName ?? this.lastConnectedName),
      );
}

class RouterNotifier extends StateNotifier<RouterState> {
  final Ref _ref;
  StreamSubscription? _scanSub;

  RouterNotifier(this._ref) : super(const RouterState()) {
    _loadSaved();
  }

  // ============================================================
  //  Persistence
  // ============================================================

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final arr = jsonDecode(raw) as List;
      final list = arr
          .map((e) => RouterInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(savedRouters: list);
    } catch (_) {}
  }

  Future<void> _saveSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(state.savedRouters.map((r) => r.toJson()).toList());
      await prefs.setString(_prefsKey, raw);
    } catch (_) {}
  }

  Future<void> _saveActive(RouterInfo? r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (r == null) {
        await prefs.remove(_prefsActiveKey);
      } else {
        await prefs.setString(_prefsActiveKey, jsonEncode(r.toJson()));
      }
    } catch (_) {}
  }

  // ============================================================
  //  Скан
  // ============================================================

  Future<void> startScan() async {
    if (state.scanning) return;
    await _scanSub?.cancel();
    state = state.copyWith(
      scanning: true,
      scannedRouters: const [],
      clearError: true,
    );

    _scanSub = RouterScanner.scan().listen(
      (router) {
        if (state.scannedRouters.any((r) => r.ip == router.ip)) return;
        state = state.copyWith(
          scannedRouters: [...state.scannedRouters, router],
        );
      },
      onDone: () {
        state = state.copyWith(scanning: false);
      },
      onError: (e) {
        state = state.copyWith(scanning: false, error: '$e');
      },
    );
  }

  void stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    state = state.copyWith(scanning: false);
  }

  // ============================================================
  //  Добавление/удаление
  // ============================================================

  /// Добавить IP вручную (с проверкой ping + platform).
  /// Возвращает RouterInfo если успех, иначе null.
  Future<RouterInfo?> addManualIp(String ip) async {
    final trimmed = ip.trim();
    if (trimmed.isEmpty) return null;

    final info = await RouterScanner.checkHost(trimmed);
    if (info == null) {
      state = state.copyWith(error: 'Роутер не отвечает на $trimmed:1062');
      return null;
    }

    if (info.platform.isEmpty) {
      state = state.copyWith(error: 'Не LaLune-бэкенд на $trimmed');
      return null;
    }

    // Добавляем и в savedRouters, и в scannedRouters, чтобы он сразу
    // появился в списке выбора.
    final saved = state.savedRouters.any((r) => r.ip == trimmed)
        ? state.savedRouters
        : [...state.savedRouters, info];
    final scanned = state.scannedRouters.any((r) => r.ip == trimmed)
        ? state.scannedRouters
        : [...state.scannedRouters, info];

    state = state.copyWith(
      savedRouters: saved,
      scannedRouters: scanned,
      clearError: true,
    );
    await _saveSaved();
    return info;
  }

  Future<void> addFromScan(RouterInfo r) async {
    if (state.savedRouters.any((x) => x.ip == r.ip)) return;
    final updated = [...state.savedRouters, r];
    state = state.copyWith(savedRouters: updated, clearError: true);
    await _saveSaved();
  }

  Future<void> removeRouter(String ip) async {
    final updated = state.savedRouters.where((r) => r.ip != ip).toList();
    state = state.copyWith(savedRouters: updated);
    await _saveSaved();
    if (state.activeRouter?.ip == ip) {
      await disconnect();
    }
  }

  // ============================================================
  //  Подключение
  // ============================================================

  /// Подключиться к роутеру:
  ///   1. Проверяем /ping роутера.
  ///   2. Читаем /core/protocols роутера и /core/protocols локально.
  ///   3. Сравниваем — если нет пересечения, блокируем.
  ///   4. Читаем свой VK-токен и POST'им на роутер /vk/token/submit.
  ///   5. ApiClient.setBaseUrl(router.ip).
  Future<bool> connect(RouterInfo router) async {
    final api = _ref.read(apiClientProvider);

    // 1. Проверка доступности.
    final pingResult = await ApiClient.pingHost(router.ip);
    if (pingResult == null) {
      state = state.copyWith(error: 'Роутер не отвечает');
      return false;
    }

    // 2. Проверка протоколов (мягкая — не блокируем при сетевых сбоях).
    try {
      final remoteProtocols = await _fetchRemoteProtocols(router.ip);
      final localProtocols = await _fetchLocalProtocols();
      final common = remoteProtocols.toSet().intersection(localProtocols.toSet());
      if (common.isEmpty) {
        state = state.copyWith(
          error: 'Протоколы не совпадают: локально ${localProtocols.join(",")}, '
              'на роутере ${remoteProtocols.join(",")}',
        );
        return false;
      }
    } catch (_) {
      // Не блокируем, если не удалось получить протоколы.
    }

    // 3. Передаём наш VK-токен на роутер.
    try {
      final raw = await api.getJson('/vk/token/raw');
      final token = (raw['token'] ?? '') as String;
      if (token.isNotEmpty) {
        await _postRemoteToken(router.ip, token);
      }
    } catch (_) {}

    // 4. Переключаем API.
    api.setBaseUrl(router.ip);
    state = state.copyWith(
      activeRouter: router,
      lastConnectedName: router.displayName,
      clearError: true,
    );
    await _saveActive(router);
    return true;
  }

  Future<void> disconnect() async {
    final api = _ref.read(apiClientProvider);
    api.resetBaseUrl();
    state = state.copyWith(clearActive: true, clearLastConnected: true);
    await _saveActive(null);
  }

  // ============================================================
  //  Remote HTTP helpers
  //  Используют ОТДЕЛЬНЫЙ http.Client, чтобы не трогать baseUrl ApiClient'а.
  // ============================================================

  Future<List<String>> _fetchLocalProtocols() async {
    try {
      final api = _ref.read(apiClientProvider);
      final list = await api.getJsonList('/core/protocols');
      final ids = list
          .map((e) => ((e as Map)['id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();
      return ids.isEmpty ? const ['CSQTT'] : ids;
    } catch (_) {
      return const ['CSQTT'];
    }
  }

  Future<List<String>> _fetchRemoteProtocols(String host) async {
    final client = http.Client();
    try {
      final uri = Uri(
        scheme: 'http',
        host: host,
        port: 1062,
        path: '/core/protocols',
      );
      final resp = await client
          .get(uri)
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return const ['CSQTT'];
      final decoded = jsonDecode(resp.body);
      if (decoded is! List) return const ['CSQTT'];
      final ids = decoded
          .map((e) => ((e as Map)['id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();
      return ids.isEmpty ? const ['CSQTT'] : ids;
    } catch (_) {
      return const ['CSQTT'];
    } finally {
      client.close();
    }
  }

  Future<void> _postRemoteToken(String host, String token) async {
    final uri = Uri(
      scheme: 'http',
      host: host,
      port: 1062,
      path: '/vk/token/submit',
    );
    await _postJsonDirect(uri, {'token': token});
  }

  Future<void> _postJsonDirect(Uri uri, Map<String, dynamic> body) async {
    final client = http.Client();
    try {
      await client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // best-effort
    } finally {
      client.close();
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }
}

final routerProvider =
    StateNotifierProvider<RouterNotifier, RouterState>((ref) {
  return RouterNotifier(ref);
});
