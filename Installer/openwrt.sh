#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# openwrt.sh — установщик LaLune для OpenWRT-роутера.
#
# Что делает:
#   1. Определяет домашнюю папку (~) и создаёт ~/.la-lune/
#   2. Скачивает:
#        ~/.la-lune/csqtt-client-aarch64    ← ядро CSQTT
#        ~/.la-lune/lalune-openwrt-backend  ← HTTP-демон LaLune (0.0.0.0:1062)
#   3. chmod +x на оба бинарника
#   4. Убивает старый backend (если был), чистит pidfile
#   5. Запускает lalune-openwrt-backend в фоне через nohup
#   6. Пишет PID в ~/.la-lune/backend.pid
#
# Использование:
#   sh openwrt.sh              — установить и запустить
#   sh openwrt.sh --force      — перекачать даже если файлы уже есть
#   sh openwrt.sh --stop       — только остановить backend
#   sh openwrt.sh --status     — показать статус
#
# Требования:
#   curl или wget, unzip не нужен.
#
# Запуск на роутере (пример):
#   wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
#   или
#   scp openwrt.sh root@192.168.1.1:/tmp/ && ssh root@192.168.1.1 "sh /tmp/openwrt.sh"

set -e

# ============================================================
#  Константы
# ============================================================

CORE_URL="https://github.com/redline-keen/csqtt-openwrt/releases/download/0.5/csqtt-client-aarch64"
BACKEND_URL="https://github.com/Endlad2/LaLune/releases/download/26.10.03.18.32/lalune-openwrt-backend"

CORE_NAME="csqtt-client-aarch64"
BACKEND_NAME="lalune-openwrt-backend"

APP_DIR="${HOME}/.la-lune"
CORE_PATH="${APP_DIR}/${CORE_NAME}"
BACKEND_PATH="${APP_DIR}/${BACKEND_NAME}"
BACKEND_PID="${APP_DIR}/backend.pid"
BACKEND_LOG="${APP_DIR}/LaLuneManager.log"

# ============================================================
#  Разбор аргументов
# ============================================================

FORCE=0
MODE="install"

for arg in "$@"; do
    case "$arg" in
        --force|-f)   FORCE=1 ;;
        --stop)       MODE="stop" ;;
        --status)     MODE="status" ;;
        -h|--help)
            sed -n '2,25p' "$0" 2>/dev/null || cat "$0" | head -25
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# ============================================================
#  Логирование
# ============================================================

log()  { printf "[openwrt] %s\n" "$*"; }
warn() { printf "[openwrt][WARN] %s\n" "$*" >&2; }
fail() { printf "[openwrt][ERROR] %s\n" "$*" >&2; exit 1; }

# ============================================================
#  Утилиты
# ============================================================

have() { command -v "$1" >/dev/null 2>&1; }

# Скачать URL в файл. Тихая докачка, retry, поддержка curl/wget.
download() {
    url="$1"
    dest="$2"
    tmp="${dest}.part"

    rm -f "$tmp"

    log "download: $url"

    if have curl; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 \
             --max-time 300 -o "$tmp" "$url" \
          || fail "curl failed for $url"
    elif have wget; then
        wget -O "$tmp" "$url" \
          || fail "wget failed for $url"
    else
        fail "нужен curl или wget"
    fi

    # Проверяем, что файл непустой.
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        fail "скачанный файл пустой: $url"
    fi

    mv -f "$tmp" "$dest"
}

# Прочитать PID из pidfile (если процесс жив).
read_pid() {
    [ -f "$BACKEND_PID" ] || return 1
    pid=$(cat "$BACKEND_PID" 2>/dev/null | tr -d ' \n\r')
    [ -n "$pid" ] || return 1
    # Проверяем, что процесс с таким PID существует.
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

# Убить старый backend.
stop_backend() {
    pid=$(read_pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        log "останавливаю старый backend (PID=$pid)"
        kill "$pid" 2>/dev/null || true
        # Даём 2 секунды на graceful shutdown.
        i=0
        while [ $i -lt 4 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 0.5
            i=$((i + 1))
        done
        # Если всё ещё жив — SIGKILL.
        if kill -0 "$pid" 2>/dev/null; then
            warn "backend не завершился, SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$BACKEND_PID"
}

# ============================================================
#  Статус
# ============================================================

print_status() {
    pid=$(read_pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        echo "LaLune OpenWRT backend: running (PID=$pid)"
        echo "  binary: $BACKEND_PATH"
        echo "  log:    $BACKEND_LOG"
        echo "  api:    http://0.0.0.0:1062"
    else
        echo "LaLune OpenWRT backend: not running"
        echo "  binary: $BACKEND_PATH"
    fi
}

# ============================================================
#  Режимы
# ============================================================

case "$MODE" in
    stop)
        stop_backend
        log "stopped."
        exit 0
        ;;
    status)
        print_status
        exit 0
        ;;
esac

# ============================================================
#  Установка
# ============================================================

log "app dir: $APP_DIR"
mkdir -p "$APP_DIR"

# --- Ядро CSQTT ---
if [ -s "$CORE_PATH" ] && [ "$FORCE" -eq 0 ]; then
    log "ядро уже есть: $CORE_PATH ($(wc -c < "$CORE_PATH") bytes)"
else
    download "$CORE_URL" "$CORE_PATH"
    chmod +x "$CORE_PATH"
    log "ядро установлено: $CORE_PATH ($(wc -c < "$CORE_PATH") bytes)"
fi

# --- Backend LaLune ---
if [ -s "$BACKEND_PATH" ] && [ "$FORCE" -eq 0 ]; then
    log "backend уже есть: $BACKEND_PATH ($(wc -c < "$BACKEND_PATH") bytes)"
else
    download "$BACKEND_URL" "$BACKEND_PATH"
    chmod +x "$BACKEND_PATH"
    log "backend установлен: $BACKEND_PATH ($(wc -c < "$BACKEND_PATH") bytes)"
fi

# --- Остановка старого процесса ---
stop_backend

# --- Запуск ---
log "запускаю backend в фоне..."
cd "$APP_DIR"

# nohup + setsid: полностью отвязать от терминала.
# На OpenWRT setsid есть в busybox — используем если есть.
if have setsid; then
    setsid nohup "$BACKEND_PATH" >>"$BACKEND_LOG" 2>&1 &
else
    nohup "$BACKEND_PATH" >>"$BACKEND_LOG" 2>&1 &
fi

new_pid=$!
echo "$new_pid" > "$BACKEND_PID"

# Ждём секунду, чтобы процесс успел стартовать/упасть.
sleep 1

if kill -0 "$new_pid" 2>/dev/null; then
    log "backend запущен (PID=$new_pid)"
    log "  log:  $BACKEND_LOG"
    log "  api:  http://0.0.0.0:1062/ping"
    log "готово."
else
    warn "backend не запустился, смотри $BACKEND_LOG"
    rm -f "$BACKEND_PID"
    tail -n 30 "$BACKEND_LOG" 2>/dev/null || true
    exit 1
fi
