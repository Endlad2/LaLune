// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Установка LaLune backend на OpenWRT по SSH.

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../api/api_client.dart';

class OpenWrtInstallResult {
  final bool ok;
  final String message;
  final String log;

  const OpenWrtInstallResult({
    required this.ok,
    required this.message,
    this.log = '',
  });
}

class OpenWrtInstaller {
  static const backendUrl =
      'https://github.com/Endlad2/LaLune/releases/latest/download/lalune-openwrt-backend';
  static const coreUrl =
      'https://github.com/Endlad2/csqtt-core/releases/latest/download/client-linux-arm64';

  static const _algorithms = SSHAlgorithms(
    kex: [
      SSHKexType.x25519Rfc,
      SSHKexType.x25519,
      SSHKexType.nistp521,
      SSHKexType.nistp384,
      SSHKexType.nistp256,
      SSHKexType.dhGexSha256,
      SSHKexType.dh14Sha256,
      // Старые Dropbear/OpenWRT могут предлагать только SHA-1 KEX.
      SSHKexType.dh14Sha1,
      SSHKexType.dhGexSha1,
      SSHKexType.dh1Sha1,
    ],
    hostkey: [
      SSHHostkeyType.ed25519,
      SSHHostkeyType.rsaSha512,
      SSHHostkeyType.rsaSha256,
      SSHHostkeyType.ecdsa521,
      SSHHostkeyType.ecdsa384,
      SSHHostkeyType.ecdsa256,
      SSHHostkeyType.rsaSha1,
    ],
    cipher: [
      SSHCipherType.aes256gcm,
      SSHCipherType.aes128gcm,
      SSHCipherType.chacha20poly1305,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes128ctr,
      // Только как fallback для старых роутеров.
      SSHCipherType.aes256cbc,
      SSHCipherType.aes128cbc,
    ],
  );

  static Future<OpenWrtInstallResult> install({
    required String host,
    required String username,
    required String password,
    void Function(String message)? onProgress,
  }) async {
    SSHClient? client;
    try {
      onProgress?.call('Подключение к SSH $host:22...');
      final socket = await SSHSocket.connect(
        host,
        22,
        timeout: const Duration(seconds: 5),
      );
      client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
        algorithms: _algorithms,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      await client.authenticated;

      onProgress?.call('Установка backend и зависимостей...');
      final script = _installScript
          .replaceAll('__BACKEND_URL__', backendUrl)
          .replaceAll('__CORE_URL__', coreUrl);
      final result = await client.runWithResult(script);
      final stdout = utf8.decode(result.stdout, allowMalformed: true);
      final stderr = utf8.decode(result.stderr, allowMalformed: true);
      final combined = [stdout.trim(), stderr.trim()]
          .where((s) => s.isNotEmpty)
          .join('\n');

      if (result.exitCode != 0 || !stdout.contains('LALUNE_INSTALL_OK')) {
        return OpenWrtInstallResult(
          ok: false,
          message: 'Установка по SSH завершилась с ошибкой',
          log: combined,
        );
      }

      onProgress?.call('Проверка LaLune API на $host:1062...');
      for (var attempt = 0; attempt < 12; attempt++) {
        final ping = await ApiClient.pingHost(
          host,
          timeout: const Duration(seconds: 2),
        );
        if (ping != null &&
            ping['ok'] == true &&
            (ping['platform'] ?? '').toString().toLowerCase() == 'openwrt') {
          return OpenWrtInstallResult(
            ok: true,
            message:
                'Установлено. Теперь выполните соединение с роутером.',
            log: combined,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      return OpenWrtInstallResult(
        ok: false,
        message:
            'Файлы установлены, но API на $host:1062 не ответил. Проверьте лог backend.',
        log: combined,
      );
    } catch (e) {
      return OpenWrtInstallResult(
        ok: false,
        message: 'Не удалось установить OpenWRT backend: $e',
      );
    } finally {
      if (client != null) {
        try {
          await client.close();
        } catch (_) {}
      }
    }
  }

  static const _installScript = r'''
set -eu

BACKEND_URL="__BACKEND_URL__"
CORE_URL="__CORE_URL__"
INSTALL_DIR="$HOME/la-lune"
DATA_DIR="$HOME/.la-lune"
BACKEND_PATH="$INSTALL_DIR/lalune-openwrt-backend"
CORE_PATH="$DATA_DIR/csqtt-client-aarch64"
PID_FILE="$DATA_DIR/backend.pid"
LOG_FILE="$DATA_DIR/LaLuneManager.log"

log() { printf '[lalune-install] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

arch="$(uname -m 2>/dev/null || true)"
case "$arch" in
  aarch64|arm64) ;;
  *)
    echo "Unsupported router architecture: $arch (need aarch64/arm64)" >&2
    exit 21
    ;;
esac

if have id && [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
  echo 'OpenWRT backend must be installed as root' >&2
  exit 20
fi

mkdir -p "$INSTALL_DIR" "$DATA_DIR"

ensure_downloader() {
  if have uclient-fetch || have wget || have curl; then
    return 0
  fi
  if have opkg; then
    log 'download utility missing; installing wget/CA certificates via opkg'
    opkg update >/dev/null 2>&1 || true
    opkg install ca-bundle ca-certificates >/dev/null 2>&1 || true
    opkg install wget-ssl >/dev/null 2>&1 || opkg install wget >/dev/null 2>&1 || true
  fi
  have uclient-fetch || have wget || have curl
}

download() {
  url="$1"
  dest="$2"
  tmp="$dest.part"
  rm -f "$tmp"
  if have uclient-fetch; then
    uclient-fetch -q -O "$tmp" "$url"
  elif have wget; then
    wget -q -O "$tmp" "$url"
  elif have curl; then
    curl -fL --retry 3 --connect-timeout 20 --max-time 300 -o "$tmp" "$url"
  else
    echo 'No downloader available' >&2
    return 1
  fi
  test -s "$tmp"
  mv -f "$tmp" "$dest"
}

ensure_downloader || {
  echo 'Could not install/find curl, wget or uclient-fetch' >&2
  exit 22
}

# Минимальные зависимости для TUN и маршрутизации. Ставим только если нужны.
if ! have ip && have opkg; then
  log 'ip utility missing; trying to install ip-full'
  opkg update >/dev/null 2>&1 || true
  opkg install ip-full >/dev/null 2>&1 || true
fi
if ! have ip; then
  echo 'ip utility is required for VPN routes' >&2
  exit 24
fi

if [ ! -c /dev/net/tun ]; then
  log '/dev/net/tun missing; trying to install/load kmod-tun'
  if have opkg; then
    opkg update >/dev/null 2>&1 || true
    opkg install kmod-tun >/dev/null 2>&1 || true
  fi
  have modprobe && modprobe tun >/dev/null 2>&1 || true
  if [ ! -e /dev/net/tun ] && have mknod; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 >/dev/null 2>&1 || true
    chmod 600 /dev/net/tun >/dev/null 2>&1 || true
  fi
fi
if [ ! -c /dev/net/tun ]; then
  echo '/dev/net/tun is unavailable; install/enable TUN support on this OpenWRT' >&2
  exit 25
fi

if ! have nohup && have opkg; then
  log 'nohup missing; trying to install coreutils-nohup'
  opkg update >/dev/null 2>&1 || true
  opkg install coreutils-nohup >/dev/null 2>&1 || true
fi
if ! have nohup; then
  echo 'nohup is required to keep backend running after SSH disconnect' >&2
  exit 26
fi

# В старых опубликованных backend могла использоваться команда `sudo` даже
# при запуске от root. Не меняем систему: даём только этому процессу shim.
COMPAT_BIN="$INSTALL_DIR/bin"
mkdir -p "$COMPAT_BIN"
cat > "$COMPAT_BIN/sudo" <<'LALUNE_SUDO_SHIM'
#!/bin/sh
exec "$@"
LALUNE_SUDO_SHIM
chmod +x "$COMPAT_BIN/sudo"

# CA bundle нужен для GitHub HTTPS на минимальных OpenWRT образах.
if have opkg && [ ! -e /etc/ssl/certs/ca-certificates.crt ] && [ ! -e /etc/ssl/cert.pem ]; then
  log 'CA certificates missing; trying to install them'
  opkg update >/dev/null 2>&1 || true
  opkg install ca-bundle ca-certificates >/dev/null 2>&1 || true
fi

log 'downloading LaLune OpenWRT backend'
download "$BACKEND_URL" "$BACKEND_PATH"
chmod +x "$BACKEND_PATH"

if [ ! -s "$CORE_PATH" ]; then
  log 'CSQTT core missing; downloading it'
  download "$CORE_URL" "$CORE_PATH"
  chmod +x "$CORE_PATH"
else
  log 'CSQTT core already installed'
fi

# Останавливаем предыдущий экземпляр, если он был запущен нашим установщиком.
if [ -f "$PID_FILE" ]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi
# Подхватываем и старую ручную установку, у которой pid-файла могло не быть.
if have killall; then
  killall lalune-openwrt-backend 2>/dev/null || true
  sleep 1
fi

log 'starting backend in background'
cd "$INSTALL_DIR"
PATH="$COMPAT_BIN:$PATH" nohup "$BACKEND_PATH" >>"$LOG_FILE" 2>&1 </dev/null &
pid=$!
echo "$pid" > "$PID_FILE"
sleep 1

if ! kill -0 "$pid" 2>/dev/null; then
  echo 'Backend exited immediately:' >&2
  tail -n 40 "$LOG_FILE" >&2 2>/dev/null || true
  exit 23
fi

printf 'LALUNE_INSTALL_OK pid=%s\n' "$pid"
''';
}
