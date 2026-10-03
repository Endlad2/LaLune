#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# build.sh — сборка LaLune backend для OpenWRT через официальный SDK.
#
# Скачивает openwrt-sdk-25.12.5-armsr-armv8_gcc-14.3.0_musl.Linux-x86_64,
# проверяет SHA256, распаковывает в .cache/openwrt-sdk/,
# собирает бинарник aarch64-unknown-linux-musl и кладёт в output/.

set -euo pipefail

# ─── Определяем корень проекта ────────────────────────────────────
# repo_root = родитель папки, где лежит этот скрипт, с .. (т.е. LaLune/).
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

sdk_name=openwrt-sdk-25.12.5-armsr-armv8_gcc-14.3.0_musl.Linux-x86_64
archive=$sdk_name.tar.zst
url=https://downloads.openwrt.org/releases/25.12.5/targets/armsr/armv8/$archive
expected_sha256=1b0316604a3e820b2b008a1baff3f9dac6716af942bef800930e58c7de98c98b
destination=${1:-$repo_root/.cache/openwrt-sdk}
sdk_root=$destination/$sdk_name
archive_path=$destination/$archive

log() {
  printf "[openwrt-build] %s\n" "$*"
}

fail() {
  printf "[openwrt-build][ERROR] %s\n" "$*" >&2
  exit 1
}

# ─── 1. Зависимости ───────────────────────────────────────────────
for cmd in curl tar zstd sha256sum cargo rustup; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "Не найдена команда: $cmd"
  fi
done

# ─── 2. Скачивание SDK ────────────────────────────────────────────
mkdir -p "$destination"

if [ -f "$archive_path" ]; then
  log "Архив уже есть: $archive_path"
else
  log "Скачиваю: $url"
  curl -fL --retry 3 --retry-delay 2 -o "$archive_path.part" "$url"
  mv "$archive_path.part" "$archive_path"
fi

# ─── 3. Проверка SHA256 ───────────────────────────────────────────
log "Проверяю SHA256..."
actual_sha=$(sha256sum "$archive_path" | awk '{print $1}')
if [ "$actual_sha" != "$expected_sha256" ]; then
  fail "SHA256 не совпадает:
  expected: $expected_sha256
  actual:   $actual_sha"
fi
log "SHA256 OK"

# ─── 4. Распаковка ────────────────────────────────────────────────
if [ -d "$sdk_root" ]; then
  log "SDK уже распакован: $sdk_root"
else
  log "Распаковываю в $destination..."
  tar --use-compress-program=unzstd -xf "$archive_path" -C "$destination"
fi

if [ ! -d "$sdk_root" ]; then
  fail "После распаковки нет $sdk_root"
fi

# ─── 5. Настройка окружения ───────────────────────────────────────
log "Настраиваю OpenWRT SDK toolchain..."

# OpenWRT SDK предоставляет staging_dir/toolchain-*/bin с gcc/ld под target.
# Мы используем его как CC/linker для C-зависимостей (rusqlite bundled,
# tun и т.д.).
toolchain_bin=$(find "$sdk_root/staging_dir" -maxdepth 2 -type d -name 'toolchain-*' | head -n1)
if [ -z "$toolchain_bin" ]; then
  fail "Не найдена toolchain в $sdk_root/staging_dir"
fi

export STAGING_DIR="$sdk_root/staging_dir"
export PATH="$toolchain_bin/bin:$sdk_root/staging_dir/host/bin:$PATH"

target_triple=aarch64-openwrt-linux-musl
rust_target=aarch64-unknown-linux-musl

cc="${target_triple}-gcc"
cxx="${target_triple}-g++"
ar="${target_triple}-ar"

if ! command -v "$cc" >/dev/null 2>&1; then
  # Иногда OpenWRT называет тулчейн короче — aarch64-openwrt-linux-musl-gcc.
  # Пробуем найти.
  cc=$(find "$toolchain_bin/bin" -maxdepth 1 -type f -name '*aarch64*gcc' | head -n1)
  if [ -z "$cc" ]; then
    fail "Не найден aarch64 gcc в $toolchain_bin/bin"
  fi
  cxx="${cc%gcc}g++"
  ar="${cc%gcc}ar"
fi

log "CC  = $cc"
log "CXX = $cxx"
log "AR  = $ar"

# ─── 6. Rust target ───────────────────────────────────────────────
if ! rustup target list --installed | grep -q "^$rust_target$"; then
  log "Добавляю rustup target: $rust_target"
  rustup target add "$rust_target"
fi

# ─── 7. Cargo config для кросс-компиляции ─────────────────────────
cargo_config_dir="$repo_root/Backend/OpenWRT/.cargo"
mkdir -p "$cargo_config_dir"

cat > "$cargo_config_dir/config.toml" <<EOF
[target.$rust_target]
linker = "$cc"
ar = "$ar"

[target.$rust_target.env]
CC_$rust_target = "$cc"
CXX_$rust_target = "$cxx"
AR_$rust_target = "$ar"
CFLAGS_$rust_target = "-I$sdk_root/staging_dir/target-aarch64-openwrt-linux-musl/usr/include"
LDFLAGS_$rust_target = "-L$sdk_root/staging_dir/target-aarch64-openwrt-linux-musl/usr/lib"
EOF

log "Cargo config: $cargo_config_dir/config.toml"

# ─── 8. Сборка ────────────────────────────────────────────────────
cd "$repo_root/Backend/OpenWRT"

log "Собираю: cargo build --release --target $rust_target"
CARGO_TARGET_DIR="$repo_root/Backend/OpenWRT/target" \
  cargo build --release --target "$rust_target"

binary="target/$rust_target/release/lalune-openwrt-backend"
if [ ! -f "$binary" ]; then
  fail "Не найден собранный бинарник: $binary"
fi

# ─── 9. Копирование результата ────────────────────────────────────
mkdir -p output
cp "$binary" output/lalune-openwrt-backend

size=$(stat -c %s output/lalune-openwrt-backend 2>/dev/null || stat -f %z output/lalune-openwrt-backend)
log "Готово: output/lalune-openwrt-backend ($((size / 1024)) KB)"
