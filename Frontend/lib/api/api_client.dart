// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// HTTP клиент к локальному бэкенду на 127.0.0.1:1062.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

class ApiClient {
  static const String _host = '127.0.0.1';
  static const int _port = 1062;
  static const Duration _timeout = Duration(seconds: 30);

  final http.Client _http;

  ApiClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

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
