#!/bin/sh
# SPDX-FileCopyrightText: 2026 luminescq
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# LaLune OpenWRT — установщик / обновлятор.
#
# Фронтенд вкомпилирован в бинарник (go:embed web), поэтому сюда его
# отдельно качать не надо.
#
# Что делает:
#   1) обновляет индекс пакетов и ставит curl, ca-bundle, kmod-tun
#      (opkg на OpenWRT <= 24.x, apk на OpenWRT >= 25.x)
#   2) Если уже стоит LaLune (бинарник + процесс на :6543):
#        - останавливает старый init-скрипт
#        - убивает процессы по PID-файлу и по порту 6543
#        - если есть /etc/csqtt/uninstall.sh — вызывает его
#          (он чистит ядро CSQTT и TUN; сам LaLune его не трогает)
#        - удаляет старый бинарник и init-скрипт
#   3) Качает свежий LaLune-owrt_aarch64 из последнего релиза
#   4) Создаёт init-скрипт, включает автозапуск, стартует
#
# Запуск:
#   wget -qO- https://raw.githubusercontent.com/Endlad2/LaLune/main/OpenWRT/lalune-owrt-install.sh | sh

set -e

BIN_URL="https://github.com/Endlad2/LaLune/releases/latest/download/LaLune-owrt_aarch64"
BIN_PATH="/usr/bin/lalune-owrt"
INIT_PATH="/etc/init.d/lalune-owrt"
CONF_DIR="/etc/csqtt"
RUN_DIR="/var/run/csqtt"
PID_FILE="/var/run/lalune-owrt.pid"
PORT=6543
CSQTT_UNINSTALL="/etc/csqtt/uninstall.sh"

log()  { echo "[LaLune] $*"; }
warn() { echo "[LaLune] ПРЕДУПРЕЖДЕНИЕ: $*" >&2; }
die()  { echo "[LaLune] ОШИБКА: $*" >&2; exit 1; }

# ============================================================
#  0. Определяем пакетный менеджер: opkg (старые OpenWRT) или apk (новые)
# ============================================================

if command -v opkg >/dev/null 2>&1; then
    PKG=opkg
    PKG_UPDATE="opkg update"
    PKG_INSTALL="opkg install"
elif command -v apk >/dev/null 2>&1; then
    PKG=apk
    # apk update тянет индексы; update вообще необязателен,
    # но для свежих индексов полезен.
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add"
else
    die "ни opkg, ни apk не найдены — не знаю, чем ставить пакеты"
fi

log "Пакетный менеджер: $PKG"

# ============================================================
#  1. Зависимости
# ============================================================

log "$PKG_UPDATE ..."
$PKG_UPDATE || warn "$PKG_UPDATE завершился с ошибкой — продолжаю"

log "Устанавливаю зависимости (curl ca-bundle kmod-tun)..."
# shellcheck disable=SC2086
$PKG_INSTALL curl ca-bundle kmod-tun || die "не удалось установить зависимости"

# ============================================================
#  2. Обнаружение и удаление старой версии
# ============================================================

# Проверяем, есть ли процесс, слушающий наш порт.
# netstat есть почти везде (busybox). lsof — редко. Пробуем по очереди.
port_in_use() {
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep -q ":${PORT}[[:space:]]"
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -i ":${PORT}" >/dev/null 2>&1
        return $?
    fi
    # Если ни netstat, ни lsof нет — считаем, что порт не занят.
    return 1
}

# Убиваем процессы LaLune: сначала по PID-файлу, потом общим killall.
kill_lalune_processes() {
    if [ -f "$PID_FILE" ]; then
        OLD_PID="$(cat "$PID_FILE" 2>/dev/null || echo)"
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            log "Убиваю процесс LaLune по PID $OLD_PID..."
            kill "$OLD_PID" 2>/dev/null || true
            sleep 1
            kill -9 "$OLD_PID" 2>/dev/null || true
        fi
    fi

    # На случай, если PID-файл потерялся, но процесс живёт.
    killall lalune-owrt 2>/dev/null || true
    sleep 1
    killall -9 lalune-owrt 2>/dev/null || true
}

OLD_BIN=0
OLD_PORT=0

[ -f "$BIN_PATH" ] && OLD_BIN=1
port_in_use && OLD_PORT=1

if [ "$OLD_BIN" = "1" ] || [ "$OLD_PORT" = "1" ]; then
    log "Обнаружена установленная версия LaLune (бинарник=$OLD_BIN, порт :$PORT занят=$OLD_PORT)."
    log "Останавливаю и удаляю старую версию..."

    # 2.1 init-скрипт
    if [ -x "$INIT_PATH" ]; then
        "$INIT_PATH" stop 2>/dev/null || true
        "$INIT_PATH" disable 2>/dev/null || true
    fi

    # 2.2 процессы
    kill_lalune_processes

    # 2.3 чужой uninstall.sh от redline-keen/csqtt-openwrt
    if [ -x "$CSQTT_UNINSTALL" ]; then
        log "Вызываю $CSQTT_UNINSTALL ..."
        sh "$CSQTT_UNINSTALL" || warn "$CSQTT_UNINSTALL завершился с ошибкой — продолжаю"
    elif [ -f "$CSQTT_UNINSTALL" ]; then
        log "Вызываю $CSQTT_UNINSTALL ..."
        sh "$CSQTT_UNINSTALL" || warn "$CSQTT_UNINSTALL завершился с ошибкой — продолжаю"
    else
        warn "$CSQTT_UNINSTALL не найден — ядро CSQTT и TUN не тронуты"
    fi

    # 2.4 старый бинарник и init
    rm -f "$BIN_PATH"
    rm -f "$INIT_PATH"
    rm -f "$PID_FILE"

    log "Старая версия удалена."
else
    log "Установленная версия LaLune не обнаружена — чистая установка."
fi

# ============================================================
#  3. Скачиваем свежий бинарник
# ============================================================

log "Скачиваю $BIN_URL ..."
curl -fsSL -o "$BIN_PATH" "$BIN_URL" || die "не удалось скачать бинарник"
chmod +x "$BIN_PATH"
log "Бинарник: $BIN_PATH"

# ============================================================
#  4. Директории и init-скрипт
# ============================================================

mkdir -p "$CONF_DIR"
mkdir -p "$RUN_DIR"
[ -f "$CONF_DIR/csqtt.log" ] || : > "$CONF_DIR/csqtt.log"

cat > "$INIT_PATH" <<'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG=/usr/bin/lalune-owrt
PIDFILE=/var/run/lalune-owrt.pid

start_service() {
    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param pidfile "$PIDFILE"
    procd_close_instance
}

stop_service() {
    killall lalune-owrt 2>/dev/null || true
    killall csqtt 2>/dev/null || true
    ip link del csqtt0 2>/dev/null || true
}
EOF

chmod +x "$INIT_PATH"

# ============================================================
#  5. Автозапуск и старт
# ============================================================

"$INIT_PATH" enable 2>/dev/null || true
"$INIT_PATH" start  2>/dev/null || true

IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "<router-ip>")

cat <<MSG

============================================================
  LaLune OpenWRT установлен.
============================================================

  Бинарник:  $BIN_PATH
  Init:      $INIT_PATH
  Веб-UI:    http://$IP:$PORT
  Конфиги:   $CONF_DIR
  Пакеты:    $PKG

  Управление:
    /etc/init.d/lalune-owrt start
    /etc/init.d/lalune-owrt stop
    /etc/init.d/lalune-owrt restart

============================================================
MSG
