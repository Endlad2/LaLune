// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/sse_client.dart';
import '../models/vpn_status.dart';
import 'providers.dart';

class VpnNotifier extends StateNotifier<VpnStatus> {
  final Ref _ref;
  Timer? _poll;
  SseClient? _sse;

  VpnNotifier(this._ref) : super(VpnStatus.empty) {
    _startPolling();
    _startSse();
  }

  void _startPolling() {
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }

  void _startSse() {
    _sse = SseClient();
    _sse!.stream.listen((ev) {
      if (ev.type == 'status') {
        final connected = (ev.data['connected'] ?? false) as bool;
        state = VpnStatus(
          state: connected ? 'connected' : 'disconnected',
          connected: connected,
          uptimeSec: state.uptimeSec,
          configId: state.configId,
          message: state.message,
        );
      } else if (ev.type == 'event' && ev.data['name'] == 'tun_ready') {
        _refresh();
      }
    });
    _sse!.connect();
  }

  Future<void> _refresh() async {
    final api = _ref.read(apiClientProvider);
    try {
      final j = await api.getJson('/vpn/status');
      state = VpnStatus.fromJson(j);
    } catch (_) {
      // backend offline — оставляем как есть
    }
  }

  Future<bool> connect(int configId) async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.postJson('/vpn/connect', {'configId': configId});
      state = VpnStatus(state: 'connecting', connected: false, configId: configId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> disconnect() async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.postJson('/vpn/disconnect', {});
      state = VpnStatus.empty;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _sse?.dispose();
    super.dispose();
  }
}

final vpnProvider = StateNotifierProvider<VpnNotifier, VpnStatus>((ref) {
  return VpnNotifier(ref);
});
