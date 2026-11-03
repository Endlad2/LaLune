import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/api/api_client.dart';
import 'package:lalune/models/settings.dart';
import 'package:lalune/state/providers.dart';
import 'package:lalune/state/settings_notifier.dart';

void main() {
  final desired = Settings(
    desktopSocks5Mode: true,
    ipRoutingMode: 'blacklist',
    ipRoutingIps: '192.0.2.8\n198.51.100.0/24',
    showCoreLogs: true,
  );

  ProviderContainer containerWith(MockClient client) {
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);
    return container;
  }

  test('confirms saved desktop settings and reloads backend values', () async {
    var stored = Settings().toJson();
    final methods = <String>[];
    final container = containerWith(MockClient((request) async {
      expect(request.url.path, '/settings');
      methods.add(request.method);
      if (request.method == 'PUT') {
        stored = jsonDecode(request.body) as Map<String, dynamic>;
        stored['deviceId'] = 'backend-managed-device';
        return http.Response('{"ok":true}', 200);
      }
      return http.Response(jsonEncode(stored), 200);
    }));
    final notifier = container.read(settingsProvider.notifier);

    expect(await notifier.save(desired), isTrue);
    expect(methods, ['PUT', 'GET']);
    expect(container.read(settingsProvider).data.deviceId,
        'backend-managed-device');
    await notifier.reload();
    final saved = container.read(settingsProvider).data;
    expect(saved.desktopSocks5Mode, isTrue);
    expect(saved.ipRoutingIps, desired.ipRoutingIps);
    expect(saved.showCoreLogs, isTrue);
    expect(container.read(settingsProvider).error, isNull);
  });

  for (final key in [
    'desktopSocks5Mode',
    'ipRoutingIps',
    'showCoreLogs',
  ]) {
    test('reports failure when backend acknowledges PUT but drops $key',
        () async {
      final stored = desired.toJson()..remove(key);
      final container = containerWith(MockClient((request) async {
        return http.Response(
            request.method == 'PUT' ? '{"ok":true}' : jsonEncode(stored), 200);
      }));

      expect(await container.read(settingsProvider.notifier).save(desired),
          isFalse);
      final error = container.read(settingsProvider).error;
      expect(error, contains('бэкенд'));
      expect(error, isNot(contains(desired.ipRoutingIps)));
    });
  }

  test('does not confirm save when readback fails', () async {
    final container = containerWith(MockClient((request) async {
      return http.Response(
          request.method == 'PUT' ? '{"ok":true}' : '{"error":"read failed"}',
          request.method == 'PUT' ? 200 : 500);
    }));
    expect(
        await container.read(settingsProvider.notifier).save(desired), isFalse);
    expect(container.read(settingsProvider).data.desktopSocks5Mode, isFalse);
    expect(container.read(settingsProvider).error, isNotNull);
  });

  test('rejects a changed IP routing mode in the backend response', () async {
    final stored = desired.toJson()..['ipRoutingMode'] = 'whitelist';
    final container = containerWith(MockClient((request) async {
      return http.Response(
          request.method == 'PUT' ? '{"ok":true}' : jsonEncode(stored), 200);
    }));
    expect(
        await container.read(settingsProvider.notifier).save(desired), isFalse);
  });

  test('an older reload cannot overwrite confirmed saved settings', () async {
    final oldResponse = Completer<http.Response>();
    var gets = 0;
    final container = containerWith(MockClient((request) async {
      if (request.method == 'PUT') return http.Response('{"ok":true}', 200);
      if (++gets == 1) return oldResponse.future;
      return http.Response(jsonEncode(desired.toJson()), 200);
    }));
    final notifier = container.read(settingsProvider.notifier);
    final reload = notifier.reload();
    expect(await notifier.save(desired), isTrue);
    oldResponse.complete(http.Response(jsonEncode(Settings().toJson()), 200));
    await reload;
    expect(container.read(settingsProvider).data.desktopSocks5Mode, isTrue);
    expect(container.read(settingsProvider).data.ipRoutingIps,
        desired.ipRoutingIps);
  });

  test('a reload response after disposal is ignored', () async {
    final response = Completer<http.Response>();
    final client = MockClient((_) => response.future);
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
    ]);
    final reload = container.read(settingsProvider.notifier).reload();
    container.dispose();
    response.complete(http.Response(jsonEncode(Settings().toJson()), 200));
    await reload;
    client.close();
  });

  test('PUT error preserves local settings and does not request readback',
      () async {
    var requests = 0;
    final container = containerWith(MockClient((request) async {
      requests++;
      expect(request.method, 'PUT');
      return http.Response('{"error":"write failed"}', 500);
    }));
    expect(
        await container.read(settingsProvider.notifier).save(desired), isFalse);
    expect(requests, 1);
    expect(container.read(settingsProvider).data.desktopSocks5Mode, isFalse);
  });

  test('does not read or confirm settings on another backend after PUT',
      () async {
    final requests = <http.Request>[];
    late ProviderContainer container;
    container = containerWith(MockClient((request) async {
      requests.add(request);
      if (request.method == 'PUT') {
        container.read(apiClientProvider).setBaseUrl('192.0.2.2');
        return http.Response('{"ok":true}', 200);
      }
      return http.Response(jsonEncode(Settings().toJson()), 200);
    }));
    expect(
        await container.read(settingsProvider.notifier).save(desired), isFalse);
    expect(requests.where((request) => request.method == 'PUT').length, 1);
    expect(container.read(settingsProvider).data.desktopSocks5Mode, isFalse);
  });
}
