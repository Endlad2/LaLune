import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/api/api_client.dart';
import 'package:lalune/models/settings.dart';
import 'package:lalune/state/logs_notifier.dart';
import 'package:lalune/state/providers.dart';
import 'package:lalune/state/settings_notifier.dart';

void main() {
  test('saved core-log toggle changes polling source and displayed lines',
      () async {
    await HttpOverrides.runZoned(() async {
      var settings = Settings().toJson();
      final sources = <String?>[];
      final client = MockClient((request) async {
        if (request.url.path == '/settings') {
          if (request.method == 'PUT') {
            settings = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(jsonEncode(settings), 200);
        }
        expect(request.url.path, '/logs/tail');
        final source = request.url.queryParameters['source'];
        sources.add(source);
        return http.Response(
            jsonEncode([
              '[INFO] backend',
              if (source == 'all') '[CORE] history from logs.log',
            ]),
            200);
      });
      final container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
      ]);
      try {
        container.read(logsProvider);
        await Future<void>.delayed(Duration.zero);
        expect(sources, ['backend']);
        expect(container.read(logsProvider).lines, ['[INFO] backend']);

        final notifier = container.read(settingsProvider.notifier);
        expect(await notifier.save(Settings(showCoreLogs: true)), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(sources.last, 'all');
        expect(container.read(logsProvider).lines,
            contains('[CORE] history from logs.log'));

        expect(await notifier.save(Settings(showCoreLogs: false)), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(sources.last, 'backend');
        expect(container.read(logsProvider).lines, ['[INFO] backend']);
      } finally {
        container.dispose();
        client.close();
      }
    }, createHttpClient: (_) => throw const SocketException('offline fixture'));
  });
}
