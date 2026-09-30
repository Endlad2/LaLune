#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 luminescq
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Сборка LaLune для iOS.
#
# Режимы:
#   SIGN_MODE=unsigned  (по умолчанию) — архив без подписи, IPA для
#                                       AltStore / Scarlet / Sideloadly.
#   SIGN_MODE=signed                   — обычный архив с автоматической
#                                       подписью; экспорт через
#                                       ExportOptions.plist.
#
# Использование:
#   ./build.sh
#   SIGN_MODE=signed ./build.sh
#
# Требования:
#   - macOS + Xcode 15+
#   - xcodegen          (brew install xcodegen)
#   - python3           (для сборки Flutter-фронтенда)
#   - flutter           (в PATH или FLUTTER_ROOT)
#   - Core/libcsqtt_ios_core.a (если нет — скрипт попробует скачать)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FRONTEND_OUT="${REPO_ROOT}/Frontend/output"
CORE_LIB="${SCRIPT_DIR}/Core/libcsqtt_ios_core.a"
CORE_URL="https://github.com/Endlad2/csqtt-core/releases/latest/download/libcsqtt_ios_core.a"

SIGN_MODE="${SIGN_MODE:-unsigned}"
ARCHIVE_PATH="${SCRIPT_DIR}/build/LaLune.xcarchive"

# ─────────────────────────────────────────────────────────────
#  1. Flutter-фронтенд
# ─────────────────────────────────────────────────────────────
echo "==> LaLune iOS build (mode: ${SIGN_MODE})"

if [ ! -f "${FRONTEND_OUT}/app.html" ] || [ ! -f "${FRONTEND_OUT}/api.js" ]; then
    echo "==> Frontend output missing — building Flutter web app for IOS..."
    ( cd "${REPO_ROOT}" && python3 build_frontend.py --platform IOS )
fi

if [ ! -f "${FRONTEND_OUT}/app.html" ]; then
    echo "error: ${FRONTEND_OUT}/app.html not found" >&2
    exit 1
fi
if [ ! -f "${FRONTEND_OUT}/api.js" ]; then
    echo "error: ${FRONTEND_OUT}/api.js not found" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────
#  2. Ядро CSQTT
# ─────────────────────────────────────────────────────────────
mkdir -p "${SCRIPT_DIR}/Core"

if [ ! -f "${CORE_LIB}" ]; then
    echo "==> libcsqtt_ios_core.a not found — downloading..."
    curl -fL --retry 3 --retry-delay 2 -o "${CORE_LIB}" "${CORE_URL}"
fi

if [ ! -f "${CORE_LIB}" ]; then
    echo "error: failed to obtain libcsqtt_ios_core.a" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────
#  3. Xcode-проект
# ─────────────────────────────────────────────────────────────
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
fi

cd "${SCRIPT_DIR}"
rm -rf build
xcodegen generate

# ─────────────────────────────────────────────────────────────
#  4. Архив
# ─────────────────────────────────────────────────────────────
if [ "${SIGN_MODE}" = "signed" ]; then
    echo "==> Signed archive (requires signing identity + provisioning profiles)"
    xcodebuild archive \
        -project LaLune.xcodeproj \
        -scheme LaLune \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "${ARCHIVE_PATH}"
else
    echo "==> Unsigned archive"
    xcodebuild archive \
        -project LaLune.xcodeproj \
        -scheme LaLune \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "${ARCHIVE_PATH}" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        DEVELOPMENT_TEAM=""
fi

# ─────────────────────────────────────────────────────────────
#  5. IPA
# ─────────────────────────────────────────────────────────────
APP_PATH="${ARCHIVE_PATH}/Products/Applications/LaLune.app"
if [ ! -d "${APP_PATH}" ]; then
    echo "error: app bundle not found at ${APP_PATH}" >&2
    find "${SCRIPT_DIR}/build" -maxdepth 5 -type d >&2 || true
    exit 1
fi

if [ ! -f "${APP_PATH}/app.html" ]; then
    echo "error: app.html was not embedded into the bundle" >&2
    exit 1
fi

echo "==> Packaging IPA"

rm -rf "${SCRIPT_DIR}/build/Payload" "${SCRIPT_DIR}/build/LaLune.ipa"
mkdir -p "${SCRIPT_DIR}/build/Payload"
cp -R "${APP_PATH}" "${SCRIPT_DIR}/build/Payload/LaLune.app"

(
    cd "${SCRIPT_DIR}/build"
    zip -qry LaLune.ipa Payload
)

echo ""
echo "Done."
echo "  Archive: ${ARCHIVE_PATH}"
echo "  IPA:     ${SCRIPT_DIR}/build/LaLune.ipa"
