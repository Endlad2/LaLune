#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# LaLune installer для Linux (CSQTT + PaperFlux).
#
# Использование:
#   ./install.sh           — скачивает всё из интернета
#   ./install.sh --ci      — использует /tmp/.la-lune_downloader/

set -euo pipefail

REPO_LALUNE="Endlad2/LaLune"
REPO_CSQTT="Endlad2/csqtt-core"
REPO_PAPERFLUX="Endlad2/PaperFlux-core"

URL_LALUNE_ZIP="https://github.com/${REPO_LALUNE}/releases/latest/download/LaLune-Linux.zip"
URL_BACKEND_ZIP="https://github.com/${REPO_LALUNE}/releases/latest/download/Backend-Linux.zip"
URL_LATEST_CSQTT="https://raw.githubusercontent.com/${REPO_CSQTT}/refs/heads/main/LATEST"
URL_LATEST_PF="https://raw.githubusercontent.com/${REPO_PAPERFLUX}/refs/heads/main/LATEST"
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
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) ;;
    esac
done

c_cyan='\033[0;36m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'
c_red='\033[0;31m'; c_gray='\033[0;90m'; c_reset='\033[0m'

step() { printf "${c_cyan}[*] %s${c_reset}\n" "$*"; }
ok()   { printf "${c_green}[+] %s${c_reset}\n" "$*"; }
warn() { printf "${c_yellow}[!] %s${c_reset}\n" "$*"; }
fail() { printf "${c_red}[-] %s${c_reset}\n" "$*" >&2; }
gray() { printf "${c_gray}    %s${c_reset}\n" "$*"; }

detect_csqtt_asset() {
    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "client-linux-x86_64" ;;
        i386|i486|i586|i686) echo "client-linux-i686" ;;
        aarch64|arm64) echo "client-linux-arm64" ;;
        armv7l|armv7) echo "client-linux-armv7" ;;
        *) fail "Неподдерживаемая архитектура: $arch"; exit 1 ;;
    esac
}

detect_pf_asset() {
    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "paperflux-linux-amd64" ;;
        aarch64|arm64) echo "paperflux-linux-arm64" ;;
        armv7l|armv7) echo "paperflux-linux-armv7" ;;
        *) fail "PaperFlux: неподдерживаемая архитектура: $arch"; exit 1 ;;
    esac
}

download() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ]; then gray "уже есть: $(basename "$dest")"; return 0; fi
    gray "скачиваю: $url"
    local tmp="${dest}.part"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 300 -o "$tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url"
    else
        fail "Нужен curl или wget"; exit 1
    fi
    mv -f "$tmp" "$dest"
}

unzip_overwrite() {
    local zip="$1" dest="$2"
    if ! command -v unzip >/dev/null 2>&1; then
        fail "Нужен unzip."; exit 1
    fi
    mkdir -p "$dest"
    unzip -oq "$zip" -d "$dest"
}

install_desktop_entry() {
    local exec_path="$1" icon_path="$2"
    mkdir -p "$APPLICATIONS_DIR" "$BIN_DIR"
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
    ln -sf "$exec_path" "$BIN_LINK"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
    fi
}

main() {
    echo
    printf "${c_green}========================================${c_reset}\n"
    printf "${c_green}     LaLune Installer (Linux)          ${c_reset}\n"
    printf "${c_green}     CSQTT + PaperFlux                 ${c_reset}\n"
    printf "${c_green}========================================${c_reset}\n"
    echo

    local csqtt_asset pf_asset
    csqtt_asset="$(detect_csqtt_asset)"
    pf_asset="$(detect_pf_asset)"
    gray "CSQTT:    $csqtt_asset"
    gray "PaperFlux: $pf_asset"

    mkdir -p "$TEMP_DIR"

    step "Получаю файлы..."
    local lalune_zip="${TEMP_DIR}/LaLune-Linux.zip"
    local backend_zip="${TEMP_DIR}/Backend-Linux.zip"
    local csqtt_exe="${TEMP_DIR}/${csqtt_asset}"
    local csqtt219_asset="${csqtt_asset}"
    local csqtt219_exe="${TEMP_DIR}/${csqtt219_asset}-2.1.9"
    local latest_csqtt219="${TEMP_DIR}/LATEST.CSQTT-2.1.9"
    local pf_exe="${TEMP_DIR}/${pf_asset}"
    local latest_csqtt="${TEMP_DIR}/LATEST.Csqtt"
    local latest_pf="${TEMP_DIR}/LATEST.PaperFlux"
    local icon_file="${TEMP_DIR}/icon.ico"

    if [ "$CI_MODE" = "1" ]; then
        [ -f "$latest_csqtt219" ] || printf '%s' '2026.09.17.17.36' > "$latest_csqtt219"
        local missing=()
        for f in "$lalune_zip" "$backend_zip" "$csqtt_exe" "$csqtt219_exe" "$pf_exe" \
                 "$latest_csqtt" "$latest_csqtt219" "$latest_pf" "$icon_file"; do
            [ -f "$f" ] || missing+=("$f")
        done
        if [ "${#missing[@]}" -gt 0 ]; then
            fail "Не хватает файлов:"; for m in "${missing[@]}"; do echo "  $m" >&2; done; exit 1
        fi
    else
        download "https://github.com/${REPO_CSQTT}/releases/latest/download/${csqtt_asset}" "$csqtt_exe"
        download "https://github.com/${REPO_CSQTT}/releases/download/2026.09.17.17.36/${csqtt_asset}" "$csqtt219_exe"
        printf '%s' '2026.09.17.17.36' > "$latest_csqtt219"
        download "https://github.com/${REPO_PAPERFLUX}/releases/latest/download/${pf_asset}" "$pf_exe"
        download "$URL_LALUNE_ZIP"  "$lalune_zip"
        download "$URL_BACKEND_ZIP" "$backend_zip"
        download "$URL_LATEST_CSQTT" "$latest_csqtt"
        download "$URL_LATEST_PF"    "$latest_pf"
        download "$URL_ICON"         "$icon_file"
    fi
    ok "файлы готовы"

    mkdir -p "$APPDATA_DIR" "$APP_DIR"
    cp -f "$icon_file" "$ICON_PATH"

    step "Распаковываю LaLune-Linux.zip"
    unzip_overwrite "$lalune_zip" "$APP_DIR"

    local launcher
    launcher="$(find "$APP_DIR" -maxdepth 2 -type f -name 'LaLune' -exec test -x {} \; -print -quit || true)"
    [ -z "$launcher" ] && launcher="$(find "$APP_DIR" -maxdepth 2 -type f -name 'lalune' -exec test -x {} \; -print -quit || true)"
    [ -z "$launcher" ] && { fail "LaLune не найден"; exit 1; }
    chmod +x "$launcher"

    step "Распаковываю Backend-Linux.zip"
    unzip_overwrite "$backend_zip" "$APPDATA_DIR"
    find "$APPDATA_DIR" -maxdepth 1 -type f \
         \( -name 'LaLuneManager' -o -name 'lalune-backend' \) \
         -exec chmod +x {} \; 2>/dev/null || true

    step "Кладу CSQTT core"
    cp -f "$csqtt_exe" "${APPDATA_DIR}/csqtt-core"
    chmod +x "${APPDATA_DIR}/csqtt-core"
    cp -f "$csqtt219_exe" "${APPDATA_DIR}/csqtt-core-2.1.9"
    chmod +x "${APPDATA_DIR}/csqtt-core-2.1.9"

    step "Кладу PaperFlux core"
    cp -f "$pf_exe" "${APPDATA_DIR}/paperflux-core"
    chmod +x "${APPDATA_DIR}/paperflux-core"

    step "Кладу LATEST-файлы"
    cp -f "$latest_csqtt" "${APPDATA_DIR}/LATEST.Csqtt"
    cp -f "$latest_csqtt219" "${APPDATA_DIR}/LATEST.CSQTT-2.1.9"
    cp -f "$latest_pf"    "${APPDATA_DIR}/LATEST.PaperFlux"

    step "Создаю ярлык в меню"
    install_desktop_entry "$launcher" "$ICON_PATH"

    step "Очищаю временные файлы"
    find "$TEMP_DIR" -maxdepth 1 -type f ! -name 'install.sh' -delete 2>/dev/null || true

    echo
    printf "${c_green}  LaLune установлен!${c_reset}\n"
    echo
    printf "  Приложение: %s\n" "$launcher"
    printf "  CSQTT:      %s\n" "${APPDATA_DIR}/csqtt-core"
    printf "  PaperFlux:  %s\n" "${APPDATA_DIR}/paperflux-core"
    echo
}

main "$@"
