#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 luminescq
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Собирает нативный хелпер и C#-бинарник для Linux.
# Требования:
#   - .NET 8 SDK
#   - gcc
#   - libgtk-3-dev, libwebkit2gtk-4.1-dev (Debian/Ubuntu)
#     или gtk3-devel, webkit2gtk4.1-devel (Fedora)
#     или gtk3, webkit2gtk-4.1 (Arch)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$SCRIPT_DIR/native"
HELPER_SRC="$NATIVE_DIR/la-lune-webview-helper.c"
HELPER_BIN="$NATIVE_DIR/la-lune-webview-helper"

echo "==> Проверка зависимостей"
command -v gcc >/dev/null || { echo "gcc не найден"; exit 1; }
command -v dotnet >/dev/null || { echo "dotnet SDK не найден"; exit 1; }

if ! pkg-config --exists gtk+-3.0; then
    echo "gtk+-3.0 не найден. Установите libgtk-3-dev / gtk3-devel / gtk3."
    exit 1
fi
if ! pkg-config --exists webkit2gtk-4.1 && ! pkg-config --exists webkit2gtk-4.0; then
    echo "webkit2gtk-4.1 (или -4.0) не найден. Установите libwebkit2gtk-4.1-dev / webkit2gtk4.1-devel / webkit2gtk-4.1."
    exit 1
fi

WEBKIT_PKG="webkit2gtk-4.1"
if ! pkg-config --exists webkit2gtk-4.1; then
    WEBKIT_PKG="webkit2gtk-4.0"
fi

echo "==> Сборка нативного хелпера"
gcc -O2 -Wall -o "$HELPER_BIN" "$HELPER_SRC" \
    $(pkg-config --cflags --libs gtk+-3.0 "$WEBKIT_PKG")
echo "    готово: $HELPER_BIN"

echo "==> Публикация C#-бинарника"
dotnet publish "$SCRIPT_DIR/LaLuneTokenFetcher.Linux.csproj" \
    -c Release -r linux-x64 --self-contained true \
    /p:PublishSingleFile=true

PUBLISH_DIR="$SCRIPT_DIR/bin/Release/net8.0/linux-x64/publish"
echo "==> Копирование хелпера в publish"
cp "$HELPER_BIN" "$PUBLISH_DIR/"

echo ""
echo "Готово."
echo "  Бинарник: $PUBLISH_DIR/LaLuneTokenFetcher"
echo "  Хелпер:   $PUBLISH_DIR/la-lune-webview-helper"
echo "  Запуск:   $PUBLISH_DIR/LaLuneTokenFetcher"
