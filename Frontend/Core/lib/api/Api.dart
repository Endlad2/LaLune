// Api.dart — unified LaLune API.
//
// "Единые имена — разные мосты": every method below has ONE name for all
// platforms, but the bridge differs:
//   * Linux / Windows  -> C / C++  via dart:ffi  (lalune_backend cdylib)
//   * Android          -> Java      via MethodChannel ("lalune/api")
//   * iOS / macOS      -> Swift     via MethodChannel ("lalune/api")
//
// The heavy lifting (TUN device) lives in LaLune/Backend (Rust, crate `tun`),
// compiled to a cross-platform library (cdylib/staticlib) with a plain C ABI.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

// C ABI signatures (see LaLune/Backend/src/lib.rs).
// NOTE: typedefs must live at file scope — Dart forbids them inside a class.
typedef _CreateC = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Int);
typedef _CreateDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int);
typedef _DestroyC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DestroyDart = void Function(ffi.Pointer<ffi.Void>);
typedef _ReadC = ffi.IntPtr Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr);
typedef _ReadDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef _WriteC = ffi.IntPtr Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr);
typedef _WriteDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef _VersionC = ffi.Pointer<ffi.Char> Function();
typedef _VersionDart = ffi.Pointer<ffi.Char> Function();

/// Result of a TUN operation.
class TunResult {
  final bool ok;
  final String? error;
  const TunResult(this.ok, [this.error]);
}

/// Unified API surface — same names, different bridges underneath.
class Api {
  Api._();

  static const MethodChannel _channel = MethodChannel('lalune/api');

  static ffi.DynamicLibrary? _lib;
  static ffi.DynamicLibrary _nativeLib() {
    _lib ??= _openNative();
    return _lib!;
  }

  static ffi.DynamicLibrary _openNative() {
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('lalune_backend.dll');
    }
    if (Platform.isLinux) {
      return ffi.DynamicLibrary.open('liblalune_backend.so');
    }
    if (Platform.isMacOS) {
      return ffi.DynamicLibrary.open('liblalune_backend.dylib');
    }
    throw UnsupportedError('FFI bridge unsupported on this platform');
  }

  static ffi.Pointer<ffi.Void>? _tunHandle;

  /// `tunCreate` — create a TUN device.
  static Future<TunResult> tunCreate({
    String name = '',
    String address = '',
    int mtu = 0,
  }) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final r = await _channel.invokeMethod<String>('tunCreate', {
          'name': name,
          'address': address,
          'mtu': mtu,
        });
        return TunResult(r != null, r);
      }
      final lib = _nativeLib();
      final create =
          lib.lookupFunction<_CreateC, _CreateDart>('lalune_tun_create');
      final n = name.isEmpty ? ffi.nullptr : name.toNativeUtf8().cast<ffi.Char>();
      final a =
          address.isEmpty ? ffi.nullptr : address.toNativeUtf8().cast<ffi.Char>();
      final h = create(n, a, mtu);
      if (h == ffi.nullptr) {
        return const TunResult(false, 'tun_create returned NULL');
      }
      _tunHandle = h;
      return const TunResult(true);
    } catch (e) {
      return TunResult(false, e.toString());
    }
  }

  /// `tunDestroy` — destroy a previously created TUN device.
  static Future<void> tunDestroy() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _channel.invokeMethod('tunDestroy');
      return;
    }
    final h = _tunHandle;
    if (h == null) return;
    final lib = _nativeLib();
    final destroy =
        lib.lookupFunction<_DestroyC, _DestroyDart>('lalune_tun_destroy');
    destroy(h);
    _tunHandle = null;
  }

  /// `tunRead` — read up to [len] bytes from the device.
  static Future<Uint8List?> tunRead(int len) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return _channel.invokeMethod<Uint8List>('tunRead', {'len': len});
    }
    final h = _tunHandle;
    if (h == null) return null;
    final lib = _nativeLib();
    final read = lib.lookupFunction<_ReadC, _ReadDart>('lalune_tun_read');
    final buf = calloc<ffi.Uint8>(len);
    try {
      final n = read(h, buf, len);
      if (n <= 0) return null;
      return Uint8List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  /// `tunWrite` — write [data] to the device. Returns bytes written or -1.
  static Future<int> tunWrite(Uint8List data) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final r = await _channel.invokeMethod<int>('tunWrite', {'data': data});
      return r ?? -1;
    }
    final h = _tunHandle;
    if (h == null) return -1;
    final lib = _nativeLib();
    final write = lib.lookupFunction<_WriteC, _WriteDart>('lalune_tun_write');
    final buf = calloc<ffi.Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      return write(h, buf, data.length);
    } finally {
      calloc.free(buf);
    }
  }

  /// `version` — backend library version string (sanity check).
  static Future<String> version() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final v = await _channel.invokeMethod<String>('version');
      return v ?? 'unknown';
    }
    final lib = _nativeLib();
    final ver = lib.lookupFunction<_VersionC, _VersionDart>('lalune_version');
    // `Utf8` comes from package:ffi (unprefixed) — ffi.Utf8 does not exist.
    return ver().cast<Utf8>().toDartString();
  }
}