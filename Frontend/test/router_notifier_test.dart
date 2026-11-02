import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/models/router_info.dart';
import 'package:lalune/state/providers.dart';
import 'package:lalune/state/router_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _routerIp = '192.0.2.1';
const _localIds = ['CSQTT 2.1.9', 'CSQTT 2.5.1', 'CSQTTR', 'PaperFlux'];

Future<
    ({
      bool connected,
      RouterState state,
      String host,
      List<http.Request> requests
    })> _connect({
  List<String> localIds = _localIds,
  Object? remoteBody = const [
    {'id': 'CSQTT'}
  ],
  int remoteStatus = 200,
  int localStatus = 200,
  bool remoteUnavailable = false,
  String initialHost = '127.0.0.1',
}) async {
  SharedPreferences.setMockInitialValues({});
  final requests = <http.Request>[];
  return http.runWithClient(() async {
    final container = ProviderContainer();
    try {
      final api = container.read(apiClientProvider);
      api.setBaseUrl(initialHost);
      final notifier = container.read(routerProvider.notifier);
      final connected = await notifier.connect(RouterInfo(ip: _routerIp));
      return (
        connected: connected,
        state: container.read(routerProvider),
        host: api.host,
        requests: requests,
      );
    } finally {
      container.dispose();
    }
  },
      () => MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/ping') {
              return http.Response('{"ok":true,"platform":"openwrt"}', 200);
            }
            if (request.url.path == '/core/protocols') {
              if (request.url.host == '127.0.0.1') {
                return http.Response(
                  jsonEncode(localIds.map((id) => {'id': id}).toList()),
                  localStatus,
                );
              }
              if (request.url.host == _routerIp) {
                if (remoteUnavailable) {
                  throw http.ClientException('unreachable');
                }
                return http.Response(jsonEncode(remoteBody), remoteStatus);
              }
              // A previously selected router must not stand in for the local backend.
              return http.Response('[{"id":"PaperFlux"}]', 200);
            }
            if (request.url.path == '/vk/token/raw') {
              return http.Response('{"token":""}', 200);
            }
            throw StateError('Unexpected request: ${request.url}');
          }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connects versioned client IDs to the legacy OpenWrt CSQTT ID',
      () async {
    final result = await _connect();
    expect(result.connected, isTrue);
    expect(result.host, _routerIp);
    expect(result.state.activeRouter?.ip, _routerIp);
    expect(result.state.error, isNull);
  });

  test('connects a legacy client ID to a known versioned router ID', () async {
    final result = await _connect(
      localIds: ['CSQTT'],
      remoteBody: [
        {'id': 'CSQTT 2.5.1'}
      ],
    );
    expect(result.connected, isTrue);
  });

  test('preserves an exact match for other protocols', () async {
    final result = await _connect(remoteBody: [
      {'id': 'PaperFlux'}
    ]);
    expect(result.connected, isTrue);
  });

  test('preserves an exact match for a versioned CSQTT ID', () async {
    final result = await _connect(
      localIds: ['CSQTT 2.1.9'],
      remoteBody: [
        {'id': 'CSQTT 2.1.9'}
      ],
    );
    expect(result.connected, isTrue);
  });

  test('normalizes case and surrounding whitespace', () async {
    final result = await _connect(remoteBody: [
      {'id': ' csqtt '}
    ]);
    expect(result.connected, isTrue);
  });

  for (final remoteId in ['CSQTT 2.5.1', 'CSQTTR', 'Unknown']) {
    test('rejects $remoteId for a CSQTT 2.1.9-only client', () async {
      final result = await _connect(
        localIds: ['CSQTT 2.1.9'],
        remoteBody: [
          {'id': remoteId}
        ],
      );
      expect(result.connected, isFalse);
      expect(result.host, '127.0.0.1');
      expect(result.state.activeRouter, isNull);
      expect(result.state.error, contains('Протоколы не совпадают'));
      expect(
          result.requests.any((r) => r.url.path == '/vk/token/raw'), isFalse);
    });
  }

  test('does not alias an unknown CSQTT version to a legacy ID', () async {
    final result = await _connect(
      localIds: ['CSQTT'],
      remoteBody: [
        {'id': 'CSQTT 99.0.0'}
      ],
    );
    expect(result.connected, isFalse);
  });

  for (final body in <Object?>[
    [],
    {},
    null,
    [
      {'id': ''}
    ],
    [
      {'id': 42}
    ],
    ['CSQTT'],
  ]) {
    test('reports invalid router capabilities: ${jsonEncode(body)}', () async {
      final result = await _connect(localIds: ['CSQTT'], remoteBody: body);
      expect(result.connected, isFalse);
      expect(result.host, '127.0.0.1');
      expect(result.state.error,
          contains('Не удалось получить список протоколов'));
    });
  }

  test('reports an HTTP error instead of inventing router capabilities',
      () async {
    final result = await _connect(localIds: ['CSQTT'], remoteStatus: 503);
    expect(result.connected, isFalse);
    expect(result.host, '127.0.0.1');
    expect(result.state.error, contains('503'));
  });

  test('reports a router capability network failure', () async {
    final result = await _connect(localIds: ['CSQTT'], remoteUnavailable: true);
    expect(result.connected, isFalse);
    expect(result.host, '127.0.0.1');
    expect(
        result.state.error, contains('Не удалось получить список протоколов'));
  });

  test('reports an HTTP error from the local backend', () async {
    final result = await _connect(localIds: ['CSQTT'], localStatus: 503);
    expect(result.connected, isFalse);
    expect(result.host, '127.0.0.1');
    expect(result.state.error, contains('503'));
  });

  test('reports an empty local capability list', () async {
    final result = await _connect(localIds: []);
    expect(result.connected, isFalse);
    expect(
        result.state.error, contains('Не удалось получить список протоколов'));
  });

  test('reads local capabilities from loopback when switching routers',
      () async {
    final result = await _connect(initialHost: '198.51.100.1');
    expect(result.connected, isTrue);
    expect(result.host, _routerIp);
    expect(
      result.requests.any(
          (r) => r.url.host == '127.0.0.1' && r.url.path == '/core/protocols'),
      isTrue,
    );
  });
}
