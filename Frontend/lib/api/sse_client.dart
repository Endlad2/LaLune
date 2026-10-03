// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SSE-клиент для /events. Простой парсер text/event-stream.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/log_line.dart';

class SseEvent {
  final String type;
  final Map<String, dynamic> data;

  SseEvent(this.type, this.data);
}

class SseClient {
  final http.Client _http;
  final Uri _uri;
  StreamSubscription? _sub;
  final _controller = StreamController<SseEvent>.broadcast();
  bool _closed = false;

  SseClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client(),
        _uri = Uri(scheme: 'http', host: '127.0.0.1', port: 1062, path: '/events');

  Stream<SseEvent> get stream => _controller.stream;

  Future<void> connect() async {
    if (_closed) return;
    try {
      final req = http.Request('GET', _uri);
      req.headers['Accept'] = 'text/event-stream';
      req.headers['Cache-Control'] = 'no-cache';
      final resp = await _http.send(req);

      if (resp.statusCode != 200) {
        _scheduleReconnect();
        return;
      }

      String buffer = '';
      _sub = resp.stream.transform(utf8.decoder).listen(
        (chunk) {
          buffer += chunk;
          // Разделяем по \n\n — это границы событий SSE.
          while (true) {
            final idx = buffer.indexOf('\n\n');
            if (idx < 0) break;
            final raw = buffer.substring(0, idx);
            buffer = buffer.substring(idx + 2);
            _handleEvent(raw);
          }
        },
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _handleEvent(String raw) {
    String? dataLine;
    for (final line in raw.split('\n')) {
      if (line.startsWith('data:')) {
        dataLine = line.substring(5).trim();
      }
    }
    if (dataLine == null || dataLine.isEmpty) return;
    try {
      final j = jsonDecode(dataLine) as Map<String, dynamic>;
      final type = (j['type'] ?? 'unknown') as String;
      _controller.add(SseEvent(type, j));
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _sub?.cancel();
    _sub = null;
    Timer(const Duration(seconds: 2), connect);
  }

  void dispose() {
    _closed = true;
    _sub?.cancel();
    _controller.close();
  }

  /// Хелпер: превращает SSE-событие типа "log" в LogLine.
  static LogLine? parseLog(SseEvent ev) {
    if (ev.type != 'log') return null;
    final line = ev.data['line'] as String? ?? '';
    final ts = (ev.data['ts'] as num?)?.toInt() ?? 0;
    return LogLine(
      line: line,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
    );
  }
}
