// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/sse_client.dart';
import '../models/vpn_status.dart';
import 'providers.dart';

class VpnNotifier extends StateNotifier<VpnStatus> {
  final Ref _ref;
  Timer? _poll;
  SseClient? _sse;
  StreamSubscription<String>? _baseUrlSub;
  bool _refreshInFlight = false;
  DateTime? _connectingSince;
  DateTime? _disconnectingSince;

  static const _connectTransitionStates = {
    'connecting',
    'checking',
  };

  bool _isConnectTransition(String value) =>
      _connectTransitionStates.contains(value);

  VpnNotifier(this._ref) : super(VpnStatus.empty) {
    _startPolling();
    _startSse();

    final api = _ref.read(apiClientProvider);
    _baseUrlSub = api.baseUrlChanges.listen((_) {
      // Переподключаем SSE на новый хост и обновляем статус.
      _sse?.dispose();
      _sse = null;
      _startSse();
      _refresh();
    });
  }

  void _startPolling() {
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }

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
      if (ev.type == 'status') {
        final connected = (ev.data['connected'] ?? false) as bool;
        final reportedState = (ev.data['state'] ??
                (connected ? 'connected' : 'disconnected'))
            .toString();
        final message = (ev.data['message'] ?? '').toString();

        // Ignore only a truly stale disconnected event during the initial
        // hand-off. Explicit backend transition states must reach the UI.
        if (!connected &&
            reportedState == 'disconnected' &&
            _isTransitionPending(_connectingSince)) {
          return;
        }
        if (connected) _connectingSince = null;
        if (!connected && !_isConnectTransition(reportedState)) {
          _disconnectingSince = null;
        }
        state = VpnStatus(
          state: reportedState,
          connected: connected,
          uptimeSec: state.uptimeSec,
          configId: state.configId,
          message: message,
        );
      } else if (ev.type == 'event' && ev.data['name'] == 'tun_ready') {
        _refresh();
      }
    });
    _sse!.connect();
  }

  bool _isTransitionPending(DateTime? since) {
    return since != null &&
        DateTime.now().difference(since) < const Duration(seconds: 20);
  }

  Future<void> _refresh() async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    final api = _ref.read(apiClientProvider);
    try {
      final j = await api.getJson('/vpn/status');
      final next = VpnStatus.fromJson(j);

      if (next.connected) {
        _connectingSince = null;
        _disconnectingSince = null;
        state = next;
      } else if (_isConnectTransition(next.state)) {
        // Backend owns the detailed startup state machine (Подключение ->
        // Проверка), so preserve it verbatim.
        state = next;
      } else if (_isTransitionPending(_connectingSince)) {
        // Keep the initial transitional UI only while the backend still reports
        // a plain disconnected state.
        state = VpnStatus(
          state: 'connecting',
          connected: false,
          uptimeSec: state.uptimeSec,
          configId: state.configId,
          message: next.message.isNotEmpty ? next.message : state.message,
        );
      } else if (_isTransitionPending(_disconnectingSince)) {
        state = VpnStatus(
          state: 'disconnecting',
          connected: false,
          uptimeSec: state.uptimeSec,
          configId: state.configId,
          message: state.message,
        );
      } else {
        _connectingSince = null;
        _disconnectingSince = null;
        state = next;
      }
    } catch (_) {
      // backend offline — оставляем как есть
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<bool> connect(int configId) async {
    final api = _ref.read(apiClientProvider);
    _connectingSince = DateTime.now();
    _disconnectingSince = null;
    state = VpnStatus(
      state: 'connecting',
      connected: false,
      configId: configId,
      message: 'Подключение',
    );
    try {
      await api.postJson('/vpn/connect', {'configId': configId});
      unawaited(_refresh());
      return true;
    } catch (e) {
      _connectingSince = null;
      final message = e is ApiException
          ? e.message
          : 'Ошибка подключения';
      state = VpnStatus(
        state: 'error',
        connected: false,
        configId: configId,
        message: message,
      );
      return false;
    }
  }

  Future<bool> disconnect() async {
    final api = _ref.read(apiClientProvider);
    _disconnectingSince = DateTime.now();
    _connectingSince = null;
    state = VpnStatus(
      state: 'disconnecting',
      connected: false,
      configId: state.configId,
      message: 'Отключение...',
    );
    try {
      await api.postJson('/vpn/disconnect', {});
      _disconnectingSince = null;
      state = VpnStatus.empty;
      return true;
    } catch (_) {
      _disconnectingSince = null;
      unawaited(_refresh());
      return false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _sse?.dispose();
    _baseUrlSub?.cancel();
    super.dispose();
  }
}

final vpnProvider = StateNotifierProvider<VpnNotifier, VpnStatus>((ref) {
  return VpnNotifier(ref);
});
