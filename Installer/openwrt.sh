#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# openwrt.sh — установщик LaLune для OpenWRT (ARM64 и ramips/mt7621).

set -e

CSQTT_URL="https://github.com/Endlad2/csqtt-core/releases/latest/download/client-linux-arm64"
PAPERFLUX_URL="https://github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-linux-arm64"
BACKEND_URL="https://github.com/Endlad2/LaLune/releases/latest/download/lalune-openwrt-backend"
RAMIPS_BACKEND_URL="https://github.com/Endlad2/LaLune/releases/latest/download/lalune-openwrt-backend-ramips"

CSQTT_NAME="csqtt-client-aarch64"
PAPERFLUX_NAME="paperflux-core"
BACKEND_NAME="lalune-openwrt-backend"

APP_DIR="${HOME}/.la-lune"
CSQTT_PATH="${APP_DIR}/${CSQTT_NAME}"
PAPERFLUX_PATH="${APP_DIR}/${PAPERFLUX_NAME}"
BACKEND_PATH="${APP_DIR}/${BACKEND_NAME}"
BACKEND_PID="${APP_DIR}/backend.pid"
BACKEND_LOG="${APP_DIR}/LaLuneManager.log"

FORCE=0
MODE="install"
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --stop)     MODE="stop" ;;
        --status)   MODE="status" ;;
        -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    esac
done

log()  { printf "[openwrt] %s\n" "$*"; }
warn() { printf "[openwrt][WARN] %s\n" "$*" >&2; }
fail() { printf "[openwrt][ERROR] %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

install_ramips_package() {
    if have apk; then
        apk add "$1"
    elif have opkg; then
        opkg update && opkg install "$1"
    else
        return 1
    fi
}

download() {
    url="$1"; dest="$2"; tmp="${dest}.part"
    rm -f "$tmp"
    log "download: $url"
    if ! (
        if have curl; then
            curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 300 -o "$tmp" "$url"
        elif have wget; then
            wget -O "$tmp" "$url"
        elif have uclient-fetch; then
            uclient-fetch -O "$tmp" "$url"
        else
            fail "нужен curl, wget или uclient-fetch"
        fi
    ) || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        fail "не удалось скачать $url"
    fi
    mv -f "$tmp" "$dest"
}

read_pid() {
    [ -f "$BACKEND_PID" ] || return 1
    pid=$(cat "$BACKEND_PID" 2>/dev/null | tr -d ' \n\r')
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

stop_backend() {
    pid=$(read_pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        log "останавливаю backend (PID=$pid)"
        kill "$pid" 2>/dev/null || true
        i=0
        while [ $i -lt 4 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
        kill -0 "$pid" 2>/dev/null && { warn "SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
    fi
    rm -f "$BACKEND_PID"
}

case "$MODE" in
    stop) stop_backend; log "stopped."; exit 0 ;;
    status)
        pid=$(read_pid 2>/dev/null || true)
        if [ -n "$pid" ]; then
            echo "LaLune OpenWRT backend: running (PID=$pid)"
        else
            echo "LaLune OpenWRT backend: not running"
        fi
        exit 0 ;;
esac

arch="$(uname -m)"
case "$arch" in
    aarch64|arm64) ;;
    mips|mipsel)
        unset DISTRIB_TARGET DISTRIB_ARCH
        [ -r /etc/openwrt_release ] && . /etc/openwrt_release
        [ "${DISTRIB_TARGET:-}" = ramips/mt7621 ] && [ "${DISTRIB_ARCH:-}" = mipsel_24kc ] \
            || fail "Нужен OpenWrt ramips/mt7621 (mipsel_24kc), обнаружено: ${DISTRIB_TARGET:-?} (${DISTRIB_ARCH:-?})"
        BACKEND_URL="$RAMIPS_BACKEND_URL"
        ;;
    *) fail "Неподдерживаемая архитектура: $arch (ARM64 или ramips/mt7621)" ;;
esac

log "app dir: $APP_DIR"
mkdir -p "$APP_DIR"

if [ "$BACKEND_URL" = "$RAMIPS_BACKEND_URL" ]; then
    if ! ip -N -4 rule show >/dev/null 2>&1; then
        install_ramips_package ip-full || true
        ip -N -4 rule show >/dev/null 2>&1 || fail "установите ip-full для маршрутизации"
    fi
    if [ ! -c /dev/net/tun ]; then
        install_ramips_package kmod-tun || true
        have modprobe && modprobe tun || true
        [ -c /dev/net/tun ] || fail "установите kmod-tun для вашей версии OpenWrt"
    fi
    if ! have nohup; then
        install_ramips_package coreutils-nohup || true
        have nohup || fail "установите coreutils-nohup"
    fi
else
    # CSQTT
    if [ -s "$CSQTT_PATH" ] && [ "$FORCE" -eq 0 ]; then
        log "csqtt уже есть: $CSQTT_PATH"
    else
        download "$CSQTT_URL" "$CSQTT_PATH"
        chmod +x "$CSQTT_PATH"
        log "csqtt установлен: $CSQTT_PATH"
    fi

    # PaperFlux
    if [ -s "$PAPERFLUX_PATH" ] && [ "$FORCE" -eq 0 ]; then
        log "paperflux уже есть: $PAPERFLUX_PATH"
    else
        download "$PAPERFLUX_URL" "$PAPERFLUX_PATH"
        chmod +x "$PAPERFLUX_PATH"
        log "paperflux установлен: $PAPERFLUX_PATH"
    fi
fi

# Старый установщик мог сохранить ARM64 backend на ramips под этим именем.
if [ "$BACKEND_URL" != "$RAMIPS_BACKEND_URL" ] && [ -s "$BACKEND_PATH" ] && [ "$FORCE" -eq 0 ]; then
    log "backend уже есть: $BACKEND_PATH"
else
    download "$BACKEND_URL" "$BACKEND_PATH"
    chmod +x "$BACKEND_PATH"
    log "backend установлен: $BACKEND_PATH"
fi

stop_backend

log "запускаю backend..."
cd "$APP_DIR"
if have setsid; then
    setsid nohup "$BACKEND_PATH" >>"$BACKEND_LOG" 2>&1 &
else
    nohup "$BACKEND_PATH" >>"$BACKEND_LOG" 2>&1 &
fi
new_pid=$!
echo "$new_pid" > "$BACKEND_PID"
sleep 1

if kill -0 "$new_pid" 2>/dev/null; then
    log "backend запущен (PID=$new_pid)"
    log "  api: http://0.0.0.0:1062/ping"
else
    warn "backend не запустился, смотри $BACKEND_LOG"
    rm -f "$BACKEND_PID"
    tail -n 30 "$BACKEND_LOG" 2>/dev/null || true
    exit 1
fi
