#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# ARM64 OpenWRT build. Builds CSQTT, CSQTTR and pinned CSQTT 2.1.9 from
# source, packs them into one ZIP and embeds that ZIP in the backend binary.

set -euo pipefail
export LC_ALL=C

backend_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$backend_dir/../.." && pwd)
cache=${1:-$repo_root/.cache/openwrt-sdk}
mkdir -p "$cache" "$backend_dir/output"
cache=$(cd -- "$cache" && pwd)
work=$(mktemp -d "$cache/build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

log() { printf '[openwrt-arm64-build] %s\n' "$*"; }
fail() { printf '[openwrt-arm64-build][ERROR] %s\n' "$*" >&2; exit 1; }

for cmd in curl tar zstd sha256sum cargo rustup unzip zip readelf; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Не найдена команда: $cmd"
done

fetch() {
    local url=$1 destination=$2 expected_sha=$3
    if [ ! -f "$destination" ]; then
        log "Скачиваю $url"
        curl --fail --location --retry 3 --retry-delay 2 --output "$work/download" "$url"
        printf '%s  %s\n' "$expected_sha" "$work/download" | sha256sum --check
        mv "$work/download" "$destination"
    else
        printf '%s  %s\n' "$expected_sha" "$destination" | sha256sum --check
    fi
}

sdk_name=openwrt-sdk-25.12.5-armsr-armv8_gcc-14.3.0_musl.Linux-x86_64
sdk_archive="$sdk_name.tar.zst"
fetch "https://downloads.openwrt.org/releases/25.12.5/targets/armsr/armv8/$sdk_archive" \
    "$cache/$sdk_archive" 1b0316604a3e820b2b008a1baff3f9dac6716af942bef800930e58c7de98c98b
sdk="$cache/$sdk_name"
if [ ! -d "$sdk" ]; then
    log "Распаковываю OpenWRT SDK"
    tar --use-compress-program=unzstd -xf "$cache/$sdk_archive" -C "$work"
    mv "$work/$sdk_name" "$sdk"
fi

export STAGING_DIR="$sdk/staging_dir"
toolchain_dir=$(find "$STAGING_DIR" -maxdepth 1 -type d -name 'toolchain-aarch64*' | head -n1)
[ -n "$toolchain_dir" ] || fail "Не найден ARM64 toolchain в $STAGING_DIR"
export PATH="$toolchain_dir/bin:$STAGING_DIR/host/bin:$PATH"

cc=$(find "$toolchain_dir/bin" -maxdepth 1 \( -type f -o -type l \) -name '*aarch64*gcc' | head -n1)
[ -n "$cc" ] || fail "Не найден aarch64 gcc"
cc=$(basename "$cc")
cxx="${cc%gcc}g++"
ar="${cc%gcc}ar"
command -v "$cc" >/dev/null 2>&1 || fail "Не найден $cc"
command -v "$cxx" >/dev/null 2>&1 || fail "Не найден $cxx"
command -v "$ar" >/dev/null 2>&1 || fail "Не найден $ar"

rust_target=aarch64-unknown-linux-musl
rustup target add "$rust_target"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$cc"
export CC_aarch64_unknown_linux_musl="$cc"
export CXX_aarch64_unknown_linux_musl="$cxx"
export AR_aarch64_unknown_linux_musl="$ar"

verify_aarch64() {
    local binary=$1 header program_headers dynamic
    header=$(readelf -h "$binary")
    program_headers=$(readelf -l "$binary")
    dynamic=$(readelf -d "$binary")
    if ! grep -q 'Class:.*ELF64' <<< "$header" ||
       ! grep -q 'Machine:.*AArch64' <<< "$header" ||
       grep -q 'INTERP' <<< "$program_headers" ||
       grep -q '(NEEDED)' <<< "$dynamic"; then
        printf 'Unexpected ARM64 ELF ABI or linkage: %s\n%s\n%s\n%s\n' \
            "$binary" "$header" "$program_headers" "$dynamic" >&2
        exit 1
    fi
    sha256sum "$binary"
}

build_core() (
    local repo=$1 commit=$2 expected_sha=$3 name=$4
    local source_zip="$cache/$repo-$commit.zip"
    fetch "https://github.com/Endlad2/$repo/archive/$commit.zip" "$source_zip" "$expected_sha"
    unzip -q "$source_zip" -d "$work"
    cd "$work/$repo-$commit/rust-client"
    export CARGO_TARGET_DIR="$cache/target-cores-aarch64/$repo-$commit"
    cargo build --locked --release --target "$rust_target" --bin client
    install -m 755 "$CARGO_TARGET_DIR/$rust_target/release/client" "$work/$name"
    verify_aarch64 "$work/$name"

    if command -v qemu-aarch64 >/dev/null 2>&1; then
        local status=0 output
        output=$(timeout 30 qemu-aarch64 "$work/$name" 2>&1) || status=$?
        if [ "$status" -ne 1 ] || ! grep -Fq -- '-peer' <<< "$output"; then
            printf 'Core startup check failed: %s (status %s)\n%s\n' "$name" "$status" "$output" >&2
            exit 1
        fi
    fi
)

# Keep ARM64 on exactly the same three source revisions as ramips.
build_core csqtt-core 181a0d9f162bb8040c255496af0aeb14828e612e \
    2e658ce1225c691b93430efdd15cc0832fe91f208585103a23b2305a925d58c1 csqtt-client
build_core csqttr-core afab4c1f279c3e132699130b95184e628f7dda1c \
    58fb9d29c5a12f3ab44260a90d22fbb53714c2d620f6eb5a64a189a1ec1927a7 csqttr-client
build_core csqtt-core eda00fce6343430b40413da01791946dccb9c6ff \
    f1c7427b4bd67ecb181c2a01eeb3455bb8959bedbe91dd29ef08650a7c10f530 csqtt-219

(
    cd "$work"
    zip -9 -X openwrt-cores.zip csqtt-client csqttr-client csqtt-219
    unzip -t openwrt-cores.zip
)
export LALUNE_OPENWRT_CORES="$work/openwrt-cores.zip"

# Backend uses the same OpenWRT SDK linker and embeds openwrt-cores.zip.
export CARGO_TARGET_DIR="$cache/target-backend-aarch64"
cd "$backend_dir"
log "Собираю backend со встроенными CSQTT/CSQTTR/CSQTT 2.1.9"
cargo build --locked --release --target "$rust_target" --bin lalune-openwrt-backend
binary="$CARGO_TARGET_DIR/$rust_target/release/lalune-openwrt-backend"
verify_aarch64 "$binary"
install -m 755 "$binary" output/lalune-openwrt-backend
cp "$LALUNE_OPENWRT_CORES" output/lalune-openwrt-cores-aarch64.zip
log "Готово: output/lalune-openwrt-backend + embedded 3-core bundle"
