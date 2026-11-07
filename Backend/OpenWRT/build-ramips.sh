#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -euo pipefail
export LC_ALL=C

backend_dir=$(cd -- "$(dirname -- "$0")" && pwd)
cache=${1:-$backend_dir/../../.cache/openwrt-ramips}
mkdir -p "$cache" "$backend_dir/output"
cache=$(cd -- "$cache" && pwd)
work=$(mktemp -d "$cache/build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

fetch() {
    local url=$1 destination=$2 expected_sha=$3
    if [ ! -f "$destination" ]; then
        curl --fail --location --retry 3 --output "$work/download" "$url"
        printf '%s  %s\n' "$expected_sha" "$work/download" | sha256sum --check
        mv "$work/download" "$destination"
    else
        printf '%s  %s\n' "$expected_sha" "$destination" | sha256sum --check
    fi
}

sdk_name=openwrt-sdk-25.12.5-ramips-mt7621_gcc-14.3.0_musl.Linux-x86_64
sdk_archive="$sdk_name.tar.zst"
fetch "https://downloads.openwrt.org/releases/25.12.5/targets/ramips/mt7621/$sdk_archive" \
    "$cache/$sdk_archive" 9962084f4131610e90e48bc864c6ceade0b238f15f335de5f672910532b20e9c
sdk="$cache/$sdk_name"
if [ ! -d "$sdk" ]; then
    tar --zstd -xf "$cache/$sdk_archive" -C "$work"
    mv "$work/$sdk_name" "$sdk"
fi

export STAGING_DIR="$sdk/staging_dir"
export PATH="$STAGING_DIR/toolchain-mipsel_24kc_gcc-14.3.0_musl/bin:$PATH"
export CARGO_TARGET_MIPSEL_UNKNOWN_LINUX_MUSL_LINKER=mipsel-openwrt-linux-musl-gcc
export CC_mipsel_unknown_linux_musl=mipsel-openwrt-linux-musl-gcc
export CXX_mipsel_unknown_linux_musl=mipsel-openwrt-linux-musl-g++
export AR_mipsel_unknown_linux_musl=mipsel-openwrt-linux-musl-ar

# Rust's static musl target requests -lunwind. The SDK ships the same _Unwind ABI in libgcc_eh.
unwind_dir="$cache/unwind"
mkdir -p "$unwind_dir"
gcc_eh=$("$CC_mipsel_unknown_linux_musl" -print-file-name=libgcc_eh.a)
gcc_lib=$("$CC_mipsel_unknown_linux_musl" -print-libgcc-file-name)
test -f "$gcc_eh" && test -f "$gcc_lib"
printf 'GROUP ( "%s" "%s" )\n' "$gcc_eh" "$gcc_lib" > "$unwind_dir/libunwind.a"
printf -v rustflags '%s\037' -C target-feature=+crt-static -C link-self-contained=no -L "native=$unwind_dir"
export CARGO_ENCODED_RUSTFLAGS="${rustflags%$'\037'}"

rust_toolchain=nightly-2026-11-06
rust_target=mipsel-unknown-linux-musl
rustup toolchain install "$rust_toolchain" --profile minimal --component rust-src

build() {
    cargo "+$rust_toolchain" build --locked --release --target "$rust_target" -Z build-std=std,panic_abort "$@"
}

verify_mipsel() {
    local binary=$1 header attributes program_headers dynamic
    header=$(readelf -h "$binary")
    attributes=$(readelf -A "$binary")
    program_headers=$(readelf -l "$binary")
    dynamic=$(readelf -d "$binary")
    if ! grep -q 'Class:.*ELF32' <<< "$header" ||
        ! grep -q 'Data:.*little endian' <<< "$header" ||
        ! grep -q 'Flags:.*o32.*mips32r2' <<< "$header" ||
        ! grep -q 'FP ABI: Soft float' <<< "$attributes" ||
        grep -q 'INTERP' <<< "$program_headers" ||
        grep -q '(NEEDED)' <<< "$dynamic"; then
        printf 'Unexpected ELF ABI or linkage: %s\n' "$binary" >&2
        printf '%s\n' "$header" "$attributes" "$program_headers" "$dynamic" >&2
        exit 1
    fi
    sha256sum "$binary"
}

build_core() (
    local repo=$1 commit=$2 expected_sha=$3 name=$4
    local zip="$cache/$repo-$commit.zip"
    fetch "https://github.com/Endlad2/$repo/archive/$commit.zip" "$zip" "$expected_sha"
    unzip -q "$zip" -d "$work"
    cd "$work/$repo-$commit/rust-client"
    python3 "$backend_dir/ramips-core-portability.py" .
    export CARGO_TARGET_DIR="$cache/target-cores"
    build --bin client
    install -m 755 "$CARGO_TARGET_DIR/$rust_target/release/client" "$work/$name"
    verify_mipsel "$work/$name"
    local status=0 log
    log=$(timeout 30 qemu-mipsel -cpu 24Kc "$work/$name" 2>&1) || status=$?
    if [ "$status" -ne 1 ] || ! grep -Fq -- '-peer' <<< "$log"; then
        printf 'Core startup check failed: %s (status %s)\n%s\n' "$name" "$status" "$log" >&2
        exit 1
    fi
)

# Endlad2's Linux workflows build rust-client's client binary in release mode.
build_core csqtt-core 181a0d9f162bb8040c255496af0aeb14828e612e \
    2e658ce1225c691b93430efdd15cc0832fe91f208585103a23b2305a925d58c1 csqtt-client-mipsel
build_core csqttr-core afab4c1f279c3e132699130b95184e628f7dda1c \
    58fb9d29c5a12f3ab44260a90d22fbb53714c2d620f6eb5a64a189a1ec1927a7 csqttr-client-mipsel
build_core csqtt-core eda00fce6343430b40413da01791946dccb9c6ff \
    f1c7427b4bd67ecb181c2a01eeb3455bb8959bedbe91dd29ef08650a7c10f530 csqtt-219-mipsel

(
    cd "$work"
    zip -9 -X ramips-cores.zip csqtt-client-mipsel csqttr-client-mipsel csqtt-219-mipsel
    unzip -t ramips-cores.zip
)
export LALUNE_RAMIPS_CORES="$work/ramips-cores.zip"
export CARGO_TARGET_DIR="$cache/target-backend"
cd "$backend_dir"
build --bin lalune-openwrt-backend
binary="$CARGO_TARGET_DIR/$rust_target/release/lalune-openwrt-backend"
verify_mipsel "$binary"
install -m 755 "$binary" output/lalune-openwrt-backend-ramips
