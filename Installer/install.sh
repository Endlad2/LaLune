#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# LaLune installer для Linux.
#
# Использование:
#   ./install.sh           — скачивает всё из интернета
#   ./install.sh --ci      — использует уже скачанные файлы
#                            из /tmp/.la-lune_downloader/
#
# Что делает:
#   1. Создаёт ~/.la-lune/
#   2. Скачивает:
#        LaLune-Linux.zip
#        Backend-Linux.zip
#        client-linux-x86_64 (или client-linux-i686 для 32-bit)
#        LATEST
#        icon.ico
#   3. Распаковывает:
#        LaLune-Linux.zip  → ~/.la-lune/app/
#        Backend-Linux.zip → ~/.la-lune/
#      и кладёт туда же ядро + LATEST + icon.ico
#   4. Создаёт:
#        ~/.local/share/applications/lalune.desktop
#        ~/.local/bin/lalune (симлинк)
#   5. Чистит временные файлы

set -euo pipefail

# ============================================================
#  Константы
# ============================================================

REPO_LALUNE="Endlad2/LaLune"
REPO_CORE="Endlad2/csqtt-core"

URL_LALUNE_ZIP="https://github.com/${REPO_LALUNE}/releases/latest/download/LaLune-Linux.zip"
URL_BACKEND_ZIP="https://github.com/${REPO_LALUNE}/releases/latest/download/Backend-Linux.zip"
URL_LATEST="https://raw.githubusercontent.com/${REPO_CORE}/refs/heads/main/LATEST"
URL_ICON="https://raw.githubusercontent.com/${REPO_LALUNE}/refs/heads/main/icon.ico"

HOME_DIR="${HOME}"
APPDATA_DIR="${HOME_DIR}/.la-lune"
APP_DIR="${APPDATA_DIR}/app"
TEMP_DIR="/tmp/.la-lune_downloader"

APPLICATIONS_DIR="${HOME_DIR}/.local/share/applications"
DESKTOP_FILE="${APPLICATIONS_DIR}/lalune.desktop"
BIN_DIR="${HOME_DIR}/.local/bin"
BIN_LINK="${BIN_DIR}/lalune"
ICON_PATH="${APPDATA_DIR}/icon.ico"

CI_MODE=0
for arg in "$@"; do
    case "$arg" in
        --ci|-ci) CI_MODE=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) ;;
    esac
done

# ============================================================
#  Логирование
# ============================================================

c_cyan='\033[0;36m'
c_green='\033[0;32m'
c_yellow='\033[1;33m'
c_red='\033[0;31m'
c_gray='\033[0;90m'
c_reset='\033[0m'

step() { printf "${c_cyan}[*] %s${c_reset}\n" "$*"; }
ok()   { printf "${c_green}[+] %s${c_reset}\n" "$*"; }
warn() { printf "${c_yellow}[!] %s${c_reset}\n" "$*"; }
fail() { printf "${c_red}[-] %s${c_reset}\n" "$*" >&2; }
gray() { printf "${c_gray}    %s${c_reset}\n" "$*"; }

# ============================================================
#  Определение архитектуры
# ============================================================

detect_core_asset() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            echo "client-linux-x86_64"
            ;;
        i386|i486|i586|i686)
            echo "client-linux-i686"
            ;;
        aarch64|arm64)
            echo "client-linux-arm64"
            ;;
        armv7l|armv7)
            echo "client-linux-armv7"
            ;;
        *)
            fail "Неподдерживаемая архитектура: $arch"
            exit 1
            ;;
    esac
}

# ============================================================
#  Скачивание
# ============================================================

download() {
    local url="$1"
    local dest="$2"

    mkdir -p "$(dirname "$dest")"

    if [ -f "$dest" ]; then
        gray "уже есть: $(basename "$dest")"
        return 0
    fi

    gray "скачиваю: $url"

    local tmp="${dest}.part"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 \
             --max-time 300 -o "$tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url"
    else
        fail "Нужен curl или wget"
        exit 1
    fi

    mv -f "$tmp" "$dest"
}

# ============================================================
#  Распаковка zip
# ============================================================

unzip_overwrite() {
    local zip="$1"
    local dest="$2"

    if ! command -v unzip >/dev/null 2>&1; then
        fail "Нужен unzip. Установите: sudo apt install unzip"
        exit 1
    fi

    mkdir -p "$dest"
    # -o: overwrite, -q: quiet
    unzip -oq "$zip" -d "$dest"
}

# ============================================================
#  Ярлык в меню приложений + симлинк в PATH
# ============================================================

install_desktop_entry() {
    local exec_path="$1"
    local icon_path="$2"

    mkdir -p "$APPLICATIONS_DIR"
    mkdir -p "$BIN_DIR"

    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=LaLune
Comment=LaLune VPN Client
Exec=${exec_path}
Icon=${icon_path}
Terminal=false
Categories=Network;VPN;
StartupNotify=true
StartupWMClass=lalune
EOF

    chmod +x "$DESKTOP_FILE"
    ok "ярлык в меню: $DESKTOP_FILE"

    # Симлинк в ~/.local/bin (если он в PATH — команда lalune будет работать).
    ln -sf "$exec_path" "$BIN_LINK"
    ok "симлинк: $BIN_LINK"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
    fi
}

# ============================================================
#  Main
# ============================================================

main() {
    echo
    printf "${c_green}========================================${c_reset}\n"
    printf "${c_green}     LaLune Installer (Linux)          ${c_reset}\n"
    printf "${c_green}========================================${c_reset}\n"
    echo

    local core_asset
    core_asset="$(detect_core_asset)"
    gray "архитектура ядра: $core_asset"

    if [ "$CI_MODE" = "1" ]; then
        step "CI-режим: файлы берутся из $TEMP_DIR"
        if [ ! -d "$TEMP_DIR" ]; then
            fail "Каталог $TEMP_DIR не найден — перезапустите без --ci"
            exit 1
        fi
    else
        step "Готовлю временный каталог: $TEMP_DIR"
        mkdir -p "$TEMP_DIR"
    fi

    # --- Скачивание / проверка ---
    step "Получаю файлы..."

    local lalune_zip="${TEMP_DIR}/LaLune-Linux.zip"
    local backend_zip="${TEMP_DIR}/Backend-Linux.zip"
    local core_exe="${TEMP_DIR}/${core_asset}"
    local latest_file="${TEMP_DIR}/LATEST"
    local icon_file="${TEMP_DIR}/icon.ico"

    if [ "$CI_MODE" = "1" ]; then
        local missing=()
        for f in "$lalune_zip" "$backend_zip" "$core_exe" "$latest_file" "$icon_file"; do
            [ -f "$f" ] || missing+=("$f")
        done
        if [ "${#missing[@]}" -gt 0 ]; then
            fail "В $TEMP_DIR не хватает файлов:"
            for m in "${missing[@]}"; do
                echo "       $m" >&2
            done
            exit 1
        fi
        ok "все файлы найдены в CI-каталоге"
    else
        download "https://github.com/${REPO_CORE}/releases/latest/download/${core_asset}" "$core_exe"
        download "$URL_LALUNE_ZIP"  "$lalune_zip"
        download "$URL_BACKEND_ZIP" "$backend_zip"
        download "$URL_LATEST"      "$latest_file"
        download "$URL_ICON"        "$icon_file"
        ok "все файлы скачаны"
    fi

    # --- Подготовка ~/.la-lune/ ---
    step "Готовлю $APPDATA_DIR"
    mkdir -p "$APPDATA_DIR"
    mkdir -p "$APP_DIR"
    ok "каталоги готовы"

    # --- Иконка ---
    step "Копирую иконку"
    cp -f "$icon_file" "$ICON_PATH"
    ok "icon.ico → $ICON_PATH"

    # --- LaLune (UI) ---
    step "Распаковываю LaLune-Linux.zip в app/"
    unzip_overwrite "$lalune_zip" "$APP_DIR"

    local launcher_exe
    launcher_exe="$(find "$APP_DIR" -maxdepth 2 -type f -name 'LaLune' \
                    -exec test -x {} \; -print -quit || true)"

    if [ -z "$launcher_exe" ]; then
        # Может быть вариант lalune (с маленькой буквы)
        launcher_exe="$(find "$APP_DIR" -maxdepth 2 -type f -name 'lalune' \
                        -exec test -x {} \; -print -quit || true)"
    fi

    if [ -z "$launcher_exe" ]; then
        fail "После распаковки LaLune не найден в $APP_DIR"
        ls -la "$APP_DIR" >&2 || true
        exit 1
    fi
    chmod +x "$launcher_exe"
    ok "бинарник: $launcher_exe"

    # --- Backend ---
    step "Распаковываю Backend-Linux.zip в .la-lune/"
    unzip_overwrite "$backend_zip" "$APPDATA_DIR"

    # Делаем исполняемыми все бинарники в ~/.la-lune (в т.ч. LaLuneManager).
    find "$APPDATA_DIR" -maxdepth 1 -type f \
         \( -name 'LaLuneManager' -o -name 'lalune-backend' \) \
         -exec chmod +x {} \; 2>/dev/null || true

    ok "backend распакован"

    # --- Ядро CSQTT ---
    step "Кладу ядро CSQTT"
    local core_dest="${APPDATA_DIR}/${core_asset}"
    cp -f "$core_exe" "$core_dest"
    chmod +x "$core_dest"
    ok "${core_asset} → $core_dest"

    # --- LATEST ---
    step "Кладу LATEST"
    cp -f "$latest_file" "${APPDATA_DIR}/LATEST"
    ok "LATEST → ${APPDATA_DIR}/LATEST"

    # --- Ярлыки ---
    step "Создаю ярлык в меню"
    install_desktop_entry "$launcher_exe" "$ICON_PATH"

    # --- Очистка временных файлов ---
    step "Очищаю временные файлы"
    find "$TEMP_DIR" -maxdepth 1 -type f \
         ! -name 'install.sh' -delete 2>/dev/null || true
    ok "готово"

    echo
    printf "${c_green}========================================${c_reset}\n"
    printf "${c_green}  LaLune установлен!                    ${c_reset}\n"
    printf "${c_green}========================================${c_reset}\n"
    echo
    printf "  Приложение: %s\n" "$launcher_exe"
    printf "  Ярлык:      %s\n" "$DESKTOP_FILE"
    printf "  Симлинк:    %s\n" "$BIN_LINK"
    echo
    if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
        warn "Добавьте $BIN_DIR в PATH, чтобы команда 'lalune' работала:"
        echo "       export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo
    fi
}

main "$@"
