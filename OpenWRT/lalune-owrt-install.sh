#!/bin/sh
# SPDX-FileCopyrightText: 2026 luminescq
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# LaLune OpenWRT — однокомандник.
#
# Фронтенд вкомпилирован в бинарник (go:embed web), поэтому сюда его
# отдельно качать не надо.
#
# Устанавливает:
#   - зависимости (curl, ca-bundle, kmod-tun)
#   - бинарник LaLune-owrt_aarch64 в /usr/bin/lalune-owrt
#   - init-скрипт /etc/init.d/lalune-owrt
#
# Запуск:
#   wget -qO- https://raw.githubusercontent.com/Endlad2/LaLune/main/OpenWRT/lalune-owrt-install.sh | sh

set -e

BIN_URL="https://github.com/Endlad2/LaLune/releases/latest/download/LaLune-owrt_aarch64"
BIN_PATH="/usr/bin/lalune-owrt"
INIT_PATH="/etc/init.d/lalune-owrt"
CONF_DIR="/etc/csqtt"

log() { echo "[LaLune] $*"; }
die() { echo "[LaLune] ОШИБКА: $*" >&2; exit 1; }

# ============================================================
#  1. Зависимости
# ============================================================

log "opkg update..."
opkg update || die "opkg update failed"

log "Устанавливаю зависимости..."
opkg install curl ca-bundle kmod-tun || die "не удалось установить зависимости"

# ============================================================
#  2. Бинарник (фронтенд уже внутри)
# ============================================================

log "Скачиваю $BIN_URL ..."
curl -fsSL -o "$BIN_PATH" "$BIN_URL" || die "не удалось скачать бинарник"
chmod +x "$BIN_PATH"
log "Бинарник: $BIN_PATH"

# ============================================================
#  3. Директории и конфиги
# ============================================================

mkdir -p "$CONF_DIR"
mkdir -p /var/run/csqtt
touch "$CONF_DIR/csqtt.log"

# ============================================================
#  4. Init-скрипт
# ============================================================

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
#  5. Автозапуск
# ============================================================

/etc/init.d/lalune-owrt enable 2>/dev/null || true
/etc/init.d/lalune-owrt start 2>/dev/null || true

IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "<router-ip>")

cat <<MSG

============================================================
  LaLune OpenWRT установлен.
============================================================

  Бинарник:  $BIN_PATH
  Init:      $INIT_PATH
  Веб-UI:    http://$IP:6543
  Конфиги:   $CONF_DIR

  Управление:
    /etc/init.d/lalune-owrt start
    /etc/init.d/lalune-owrt stop
    /etc/init.d/lalune-owrt restart

============================================================
MSG
