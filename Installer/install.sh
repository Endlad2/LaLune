#!/usr/bin/env bash
set -euo pipefail

REPO_LALUNE="Endlad2/LaLune"
REPO_CSQTT="Endlad2/csqtt-core"
REPO_PAPERFLUX="Endlad2/PaperFlux-core"
REPO_FREETURN="hackdiaz-dev/free-turn-proxy"

URL_LALUNE_ZIP="https://github.com/${REPO_LALUNE}/releases/latest/download/LaLune-Linux.zip"
URL_BACKEND_ZIP="https://github.com/${REPO_LALUNE}/releases/latest/download/Backend-Linux.zip"
URL_LATEST_CSQTT="https://raw.githubusercontent.com/${REPO_CSQTT}/refs/heads/main/LATEST"
URL_LATEST_PF="https://raw.githubusercontent.com/${REPO_PAPERFLUX}/refs/heads/main/LATEST"
URL_ICON="https://raw.githubusercontent.com/${REPO_LALUNE}/refs/heads/main/icon.ico"

HOME_DIR="${HOME}"
APPDATA_DIR="${HOME_DIR}/.la-lune"
APP_DIR="${APPDATA_DIR}/app"
TEMP_DIR="/tmp/.la-lune_downloader"
ICON_PATH="${APPDATA_DIR}/icon.ico"
CI_MODE=0

for arg in "$@"; do
    [[ "$arg" == "--ci" ]] && CI_MODE=1
done

c_cyan='\033[0;36m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
step() { printf "${c_cyan}[*] %s${c_reset}\n" "$*"; }
ok()   { printf "${c_green}[+] %s${c_reset}\n" "$*"; }
fail() { printf "${c_red}[-] %s${c_reset}\n" "$*" >&2; }

detect_csqtt_asset() {
    local arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "client-linux-x86_64" ;;
        aarch64|arm64) echo "client-linux-arm64" ;;
        *) fail "Неподдерживаемая архитектура: $arch"; exit 1 ;;
    esac
}

detect_pf_asset() {
    local arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "paperflux-linux-amd64" ;;
        *) echo "paperflux-linux-amd64" ;; # fallback
    esac
}

download() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ]; then return 0; fi
    local tmp="${dest}.part"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url"
    fi
    mv -f "$tmp" "$dest"
}

unzip_overwrite() {
    local zip="$1" dest="$2"
    mkdir -p "$dest"
    unzip -oq "$zip" -d "$dest"
}

install_desktop_entry() {
    local exec_path="$1" icon_path="$2"
    mkdir -p "${HOME_DIR}/.local/share/applications" "${HOME_DIR}/.local/bin"
    cat > "${HOME_DIR}/.local/share/applications/lalune.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LaLune
Comment=LaLune VPN Client
Exec=${exec_path}
Icon=${icon_path}
Terminal=false
Categories=Network;VPN;
EOF
    chmod +x "${HOME_DIR}/.local/share/applications/lalune.desktop"
    ln -sf "$exec_path" "${HOME_DIR}/.local/bin/lalune"
}

main() {
    echo -e "${c_green}========================================${c_reset}"
    echo -e "${c_green}     LaLune Installer (Linux) + FreeTurn${c_reset}"
    echo -e "${c_green}========================================${c_reset}"

    local csqtt_asset=$(detect_csqtt_asset)
    local pf_asset=$(detect_pf_asset)
    mkdir -p "$TEMP_DIR"

    local lalune_zip="${TEMP_DIR}/LaLune-Linux.zip"
    local backend_zip="${TEMP_DIR}/Backend-Linux.zip"
    local csqtt_exe="${TEMP_DIR}/${csqtt_asset}"
    local pf_exe="${TEMP_DIR}/${pf_asset}"
    local ft_exe="${TEMP_DIR}/client-linux-amd64"
    local latest_csqtt="${TEMP_DIR}/LATEST.Csqtt"
    local latest_pf="${TEMP_DIR}/LATEST.PaperFlux"
    local icon_file="${TEMP_DIR}/icon.ico"

    if [ "$CI_MODE" = "0" ]; then
        download "https://github.com/${REPO_CSQTT}/releases/latest/download/${csqtt_asset}" "$csqtt_exe"
        download "https://github.com/${REPO_PAPERFLUX}/releases/latest/download/${pf_asset}" "$pf_exe"
        download "https://github.com/${REPO_FREETURN}/releases/latest/download/client-linux-amd64" "$ft_exe"
        download "$URL_LALUNE_ZIP"  "$lalune_zip"
        download "$URL_BACKEND_ZIP" "$backend_zip"
        download "$URL_LATEST_CSQTT" "$latest_csqtt"
        download "$URL_LATEST_PF"    "$latest_pf"
        download "$URL_ICON"         "$icon_file"
    fi

    mkdir -p "$APPDATA_DIR" "$APP_DIR"
    cp -f "$icon_file" "$ICON_PATH"

    unzip_overwrite "$lalune_zip" "$APP_DIR"
    local launcher=$(find "$APP_DIR" -maxdepth 2 -type f -name 'LaLune' | head -n 1)
    chmod +x "$launcher"

    unzip_overwrite "$backend_zip" "$APPDATA_DIR"
    find "$APPDATA_DIR" -maxdepth 1 -type f -name 'LaLuneManager' -exec chmod +x {} \; 2>/dev/null || true

    cp -f "$csqtt_exe" "${APPDATA_DIR}/csqtt-core"
    chmod +x "${APPDATA_DIR}/csqtt-core"
    
    cp -f "$pf_exe" "${APPDATA_DIR}/paperflux-core"
    chmod +x "${APPDATA_DIR}/paperflux-core"

    cp -f "$ft_exe" "${APPDATA_DIR}/freeturn-core"
    chmod +x "${APPDATA_DIR}/freeturn-core"

    cp -f "$latest_csqtt" "${APPDATA_DIR}/LATEST.Csqtt"
    cp -f "$latest_pf"    "${APPDATA_DIR}/LATEST.PaperFlux"
    echo "latest" > "${APPDATA_DIR}/LATEST.FreeTurn"

    install_desktop_entry "$launcher" "$ICON_PATH"

    echo -e "${c_green}  LaLune установлен! (включая FreeTurn)${c_reset}"
}

main "$@"
