// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// HTTP клиент к бэкенду.
//
// По умолчанию — 127.0.0.1:1062. Но если UI подключён к OpenWRT-роутеру,
// baseUrl переключается на IP роутера (192.168.x.y:1062).
//
// Метод setBaseUrl() меняет адрес для ВСЕХ последующих запросов.
// При подключении к роутеру UI вызывает setBaseUrl(routerIp),
// при отключении — setBaseUrl('127.0.0.1').
//
// Все notifier'ы подписаны на baseUrlChanges и перезагружают данные.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

class ApiClient {
  static const String _defaultHost = '127.0.0.1';
  static const int _port = 1062;
  static const Duration _timeout = Duration(seconds: 30);

  final http.Client _http;

  /// Текущий host — изменяется через setBaseUrl.
  String _host = _defaultHost;

  /// Слушатели смены baseUrl (notifier'ы перезагружают данные).
  final _baseUrlChanges = StreamController<String>.broadcast();

  ApiClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  String get host => _host;
  int get port => _port;
  String get baseUrl => 'http://$_host:$_port';
  bool get isLocalhost => _host == _defaultHost;
  Stream<String> get baseUrlChanges => _baseUrlChanges.stream;

  /// Переключить API на другой хост (или обратно на 127.0.0.1).
  void setBaseUrl(String host, {int? port}) {
    if (_host == host) return;
    _host = host;
    _baseUrlChanges.add(baseUrl);
  }

  /// Вернуть API на localhost.
  void resetBaseUrl() => setBaseUrl(_defaultHost);

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri(
      scheme: 'http',
      host: _host,
      port: _port,
      path: path,
      queryParameters: query,
    );
  }

  Future<Map<String, dynamic>> getJson(String path,
      {Map<String, String>? query}) async {
    try {
      final resp = await _http.get(_uri(path, query)).timeout(_timeout);
      return _decode(resp);
    } on TimeoutException {
      throw ApiException('timeout: $path');
    } catch (e) {
      throw ApiException('$e');
    }
  }

  Future<List<dynamic>> getJsonList(String path,
      {Map<String, String>? query}) async {
    try {
      final resp = await _http.get(_uri(path, query)).timeout(_timeout);
      return _decodeList(resp);
    } on TimeoutException {
      throw ApiException('timeout: $path');
    } catch (e) {
      throw ApiException('$e');
    }
  }

  Future<Map<String, dynamic>> postJson(
      String path, Map<String, dynamic> body) async {
    try {
      final resp = await _http
          .post(
            _uri(path),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      return _decode(resp);
    } on TimeoutException {
      throw ApiException('timeout: $path');
    } catch (e) {
      throw ApiException('$e');
    }
  }

  Future<Map<String, dynamic>> putJson(
      String path, Map<String, dynamic> body) async {
    try {
      final resp = await _http
          .put(
            _uri(path),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      return _decode(resp);
    } on TimeoutException {
      throw ApiException('timeout: $path');
    } catch (e) {
      throw ApiException('$e');
    }
  }

  Future<Map<String, dynamic>> patchJson(
      String path, Map<String, dynamic> body) async {
    try {
      final resp = await _http
          .patch(
            _uri(path),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      return _decode(resp);
    } on TimeoutException {
      throw ApiException('timeout: $path');
    } catch (e) {
      throw ApiException('$e');
    }
  }

  Future<Map<String, dynamic>> deleteJson(String path) async {
    try {
      final resp = await _http.delete(_uri(path)).timeout(_timeout);
      return _decode(resp);
    } on TimeoutException {
      throw ApiException('timeout: $path');
    } catch (e) {
      throw ApiException('$e');
    }
  }

  Future<bool> ping() async {
    try {
      final resp = await _http
          .get(_uri('/ping'))
          .timeout(const Duration(seconds: 2));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Пинг конкретного хоста (для сканера роутеров).
  /// Возвращает распарсенный /ping или null.
  static Future<Map<String, dynamic>?> pingHost(String host,
      {Duration timeout = const Duration(milliseconds: 800)}) async {
    try {
      final uri = Uri(scheme: 'http', host: host, port: _port, path: '/ping');
      final client = http.Client();
      try {
        final resp = await client.get(uri).timeout(timeout);
        if (resp.statusCode != 200) return null;
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        return j;
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decode(http.Response resp) {
    if (resp.statusCode >= 400) {
      String msg = 'HTTP ${resp.statusCode}';
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        if (j['error'] != null) msg = j['error'] as String;
      } catch (_) {}
      throw ApiException(msg, statusCode: resp.statusCode);
    }
    if (resp.body.isEmpty) return {};
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw ApiException('invalid json: $e');
    }
  }

  List<dynamic> _decodeList(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw ApiException('HTTP ${resp.statusCode}', statusCode: resp.statusCode);
    }
    if (resp.body.isEmpty) return [];
    try {
      return jsonDecode(resp.body) as List<dynamic>;
    } catch (e) {
      throw ApiException('invalid json: $e');
    }
  }
}
