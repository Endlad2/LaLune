# Патч Backend/Desktop/Cargo.toml

Добавить зависимость на локальный крейт `csqtt-link`:

```toml
[dependencies]
# ... существующие ...
csqtt-link = { path = "../../Core/csqtt-link" }
```

После этого в `src/config.rs`:

1. Добавить `mod csqtt_link_bridge;` в `src/main.rs` (рядом с `mod config;`).
2. Заменить `parse_csqtt` на версию из `config.cs.patch.rs`.
3. Убедиться, что `parse_csqtt_native` остаётся (fallback).

## Проверка

```
cd Backend/Desktop
cargo build --release
```

</BDS:create_file>

<BDS:create_file fileName="Backend/OpenWRT/Cargo.toml.patch.md">

```markdown
# Патч Backend/OpenWRT/Cargo.toml

Добавить зависимость на локальный крейт `csqtt-link`:

```toml
[dependencies]
# ... существующие ...
csqtt-link = { path = "../../Core/csqtt-link" }

В `src/main.rs`:

```
mod csqtt_link_bridge;
```

В `src/config.rs` — заменить `parse_csqtt` на версию из
`Backend/Desktop/src/config.cs.patch.rs` (идентична).

</BDS:create_file>

<BDS:create_file fileName=".github/workflows/build.yml">

```yaml
name: Build LaLune

on:
  push:
    branches: [main, release]
  workflow_dispatch:

permissions:
  contents: write

env:
  PYTHONIOENCODING: utf-8
  PYTHONUTF8: "1"
  FLUTTER_VERSION: "3.29.0"
  RUST_VERSION: "stable"

jobs:

  # ============================================================
  #  Desktop Linux
  # ============================================================
  build-desktop-linux:
    name: Desktop Linux
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: ${{ env.RUST_VERSION }}
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true
      - name: Install Linux desktop build deps
        run: |
          sudo apt-get update
          sudo apt-get install -y clang cmake ninja-build pkg-config \
            libgtk-3-dev liblzma-dev libstdc++-12-dev
      - name: Install Pillow
        run: python -m pip install --upgrade pip Pillow
      - name: Generate icons
        run: python make_icons.py
      - name: Build (CI mode)
        run: python build.py --ci --target linux
      - uses: actions/upload-artifact@v4
        with:
          name: Output-Linux
          path: Output/*.zip
          if-no-files-found: error

  # ============================================================
  #  Desktop Windows
  # ============================================================
  build-desktop-windows:
    name: Desktop Windows
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: ${{ env.RUST_VERSION }}
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true
      - name: Install VS2022 (Native Desktop C++)
        shell: pwsh
        run: |
          choco install visualstudio2022community -y --no-progress `
            --package-parameters "--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
      - name: Setup MSVC
        uses: ilammy/msvc-dev-cmd@v1
        with:
          arch: x64
      - name: Install Pillow
        run: python -m pip install --upgrade pip Pillow
      - name: Generate icons
        run: python make_icons.py
      - name: Build (CI mode)
        shell: cmd
        run: python build.py --ci --target windows
      - uses: actions/upload-artifact@v4
        with:
          name: Output-Windows
          path: Output/*.zip
          if-no-files-found: error

  # ============================================================
  #  OpenWRT
  # ============================================================
  build-desktop-openwrt:
    name: OpenWRT Backend (armsr/armv8)
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: ${{ env.RUST_VERSION }}
          targets: aarch64-unknown-linux-musl
      - name: Install system deps
        run: |
          sudo apt-get update
          sudo apt-get install -y curl zstd
      - name: Build OpenWRT backend
        working-directory: Backend/OpenWRT
        run: |
          chmod +x build.sh
          ./build.sh
      - uses: actions/upload-artifact@v4
        with:
          name: Output-OpenWRT
          path: Backend/OpenWRT/output/lalune-openwrt-backend
          if-no-files-found: error

  # ============================================================
  #  csqtt-link: standalone CLI для всех платформ
  # ============================================================
  build-csqtt-link:
    name: "csqtt-link - ${{ matrix.platform }}"
    runs-on: ${{ matrix.runner }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: Windows
            runner: windows-latest
            target: x86_64-pc-windows-msvc
          - platform: Linux
            runner: ubuntu-22.04
            target: x86_64-unknown-linux-musl
          - platform: OpenWRT
            runner: ubuntu-22.04
            target: aarch64-unknown-linux-musl
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: ${{ env.RUST_VERSION }}
          targets: ${{ matrix.target }}
      - name: Install musl tools (Linux/OpenWRT)
        if: matrix.platform != 'Windows'
        run: |
          sudo apt-get update
          sudo apt-get install -y musl-tools
      - name: Build csqtt-link
        working-directory: Core/csqtt-link
        run: |
          cargo build --release --target ${{ matrix.target }}
      - name: Stage output
        shell: bash
        run: |
          mkdir -p Output
          SRC="Core/csqtt-link/target/${{ matrix.target }}/release"
          if [ "${{ matrix.platform }}" = "Windows" ]; then
            cp "$SRC/csqtt-link.exe" "Output/csqtt-link-Windows.exe"
          else
            cp "$SRC/csqtt-link" "Output/csqtt-link-${{ matrix.platform }}"
          fi
      - uses: actions/upload-artifact@v4
        with:
          name: csqtt-link-${{ matrix.platform }}
          path: Output/csqtt-link-*
          if-no-files-found: error

  # ============================================================
  #  Android APK
  # ============================================================
  build-android:
    name: Android APK (universal)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ env.FLUTTER_VERSION }}
          channel: stable
          cache: true
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: ${{ env.RUST_VERSION }}
          targets: aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android
      - name: Android SDK path
        run: |
          if [ -z "$ANDROID_HOME" ] && [ -d "/usr/local/lib/android/sdk" ]; then
            echo "ANDROID_HOME=/usr/local/lib/android/sdk" >> $GITHUB_ENV
            echo "ANDROID_SDK_ROOT=/usr/local/lib/android/sdk" >> $GITHUB_ENV
          fi
      - name: Install NDK
        run: yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "ndk;27.0.12077973" >/dev/null 2>&1 || true
      - name: Install cargo-ndk
        run: cargo install cargo-ndk
      - name: Build csqtt-link for Android (libcsqtt_decode.so)
        working-directory: Core/csqtt-link
        run: |
          export NDK_HOME="$ANDROID_HOME/ndk/27.0.12077973"
          cargo ndk \
            --target aarch64-linux-android \
            --target armv7-linux-androideabi \
            --target x86_64-linux-android \
            --platform 24 \
            -o ../../Frontend/android/app/src/main/jniLibs \
            build --release
      - name: Copy Android backend
        run: |
          DST="Frontend/android/app/src/main/kotlin/com/lalune/lalune"
          mkdir -p "$DST"
          cp Backend/Android/*.kt "$DST/"
      - name: Copy assets
        run: |
          rm -rf Frontend/assets
          cp -r Assets Frontend/assets
      - name: Download CSQTT cores (jniLibs)
        run: |
          mkdir -p Frontend/android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}
          curl -L --fail --retry 3 -o Frontend/android/app/src/main/jniLibs/arm64-v8a/libclient-android-arm64-v8a.so \
            https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-arm64-v8a.so
          curl -L --fail --retry 3 -o Frontend/android/app/src/main/jniLibs/armeabi-v7a/libclient-android-armeabi-v7a.so \
            https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-armeabi-v7a.so
          curl -L --fail --retry 3 -o Frontend/android/app/src/main/jniLibs/x86_64/libclient-android-x86_64.so \
            https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-x86_64.so
      - name: Download PaperFlux cores (jniLibs)
        run: |
          TMP_PF=$(mktemp -d)
          curl -L --fail --retry 3 -o "$TMP_PF/paperflux-android.zip" \
            https://github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-android.zip
          unzip -o "$TMP_PF/paperflux-android.zip" -d "$TMP_PF/extracted"
          for abi in arm64-v8a armeabi-v7a x86_64 x86; do
            mkdir -p "Frontend/android/app/src/main/jniLibs/$abi"
            SRC="$TMP_PF/extracted/$abi/libopenflux.so"
            if [ -f "$SRC" ]; then
              cp "$SRC" "Frontend/android/app/src/main/jniLibs/$abi/libopenflux.so"
            fi
          done
          rm -rf "$TMP_PF"
          ls -laR Frontend/android/app/src/main/jniLibs/ | head -60
      - name: Copy Lua scripts to assets
        run: |
          mkdir -p Frontend/android/app/src/main/assets
          cp Core/SmartTunnel.lua   Frontend/android/app/src/main/assets/SmartTunnel.lua
          cp Core/csqtt_decode.lua  Frontend/android/app/src/main/assets/csqtt_decode.lua
      - name: Install Pillow
        run: python -m pip install --upgrade pip Pillow
      - name: Generate icons
        run: python make_icons.py
      - name: Flutter pub get
        working-directory: Frontend
        run: flutter pub get
      - name: Generate launcher icons
        working-directory: Frontend
        run: flutter pub run flutter_launcher_icons
      - name: Build APK
        working-directory: Frontend
        run: flutter build apk --debug
      - name: Locate & rename APK
        run: |
          APK=$(find Frontend/build/app/outputs/flutter-apk -name "app-debug.apk" -type f | head -n 1)
          [ -z "$APK" ] && exit 1
          mkdir -p Output
          cp "$APK" Output/LaLune-Android.apk
      - uses: actions/upload-artifact@v4
        with:
          name: Output-Android
          path: Output/LaLune-Android.apk
          if-no-files-found: error

  # ============================================================
  #  csqtt-link для iOS (staticlib → .a)
  # ============================================================
  build-csqtt-link-ios:
    name: csqtt-link iOS (staticlib)
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: ${{ env.RUST_VERSION }}
          targets: aarch64-apple-ios,aarch64-apple-ios-sim
      - name: Build staticlib for iOS
        working-directory: Core/csqtt-link
        run: |
          cargo build --release --target aarch64-apple-ios
          cargo build --release --target aarch64-apple-ios-sim
      - name: Combine into xcframework
        run: |
          mkdir -p Output
          xcodebuild -create-xcframework \
            -library "Core/csqtt-link/target/aarch64-apple-ios/release/libcsqtt_link.a" \
            -library "Core/csqtt-link/target/aarch64-apple-ios-sim/release/libcsqtt_link.a" \
            -output "Output/csqtt_link.xcframework" || true
          if [ ! -d "Output/csqtt_link.xcframework" ]; then
            cp "Core/csqtt-link/target/aarch64-apple-ios/release/libcsqtt_link.a" Output/
          fi
      - uses: actions/upload-artifact@v4
        with:
          name: csqtt-link-iOS
          path: Output/*
          if-no-files-found: error

  # ============================================================
  #  Token Fetcher
  # ============================================================
  build-token-fetcher:
    name: "Token Fetcher - ${{ matrix.platform }}"
    runs-on: ${{ matrix.runner }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: Windows
            runner: windows-latest
          - platform: Linux
            runner: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: "8.0.x"
      - name: Build fetcher
        run: python build_token_grabber.py --platform ${{ matrix.platform }}
      - name: Package into zip
        shell: bash
        run: |
          set -e
          OUTPUT_BIN="Core/LaLuneTokenFetcher/output/LaLuneTokenFetcher"
          ZIP_PATH="Core/LaLuneTokenFetcher/LaLuneTokenFetcher_${{ matrix.platform }}.zip"
          [ -d "$OUTPUT_BIN" ] || { find Core/LaLuneTokenFetcher/output -maxdepth 2 -type d || true; exit 1; }
          STAGING="Core/LaLuneTokenFetcher/output/_staging"
          rm -rf "$STAGING"
          mkdir -p "$STAGING/vk-token-fetcher"
          cp -r "$OUTPUT_BIN/." "$STAGING/vk-token-fetcher/"
          if [ "${{ matrix.platform }}" = "Linux" ]; then
            chmod +x "$STAGING/vk-token-fetcher/LaLuneTokenFetcher" || true
          fi
          rm -f "$ZIP_PATH"
          pushd "$STAGING" >/dev/null
          if [ "${{ matrix.platform }}" = "Windows" ]; then
            popd >/dev/null
            powershell -Command "Compress-Archive -Path 'Core/LaLuneTokenFetcher/output/_staging/vk-token-fetcher' -DestinationPath '$ZIP_PATH' -Force"
          else
            zip -r "../../LaLuneTokenFetcher_${{ matrix.platform }}.zip" "vk-token-fetcher"
            popd >/dev/null
          fi
      - uses: actions/upload-artifact@v4
        with:
          name: LaLuneTokenFetcher-${{ matrix.platform }}
          path: Core/LaLuneTokenFetcher/LaLuneTokenFetcher_${{ matrix.platform }}.zip
          if-no-files-found: error

  # ============================================================
  #  Release
  # ============================================================
  create-release:
    name: Create Release
    needs:
      - build-desktop-linux
      - build-desktop-windows
      - build-desktop-openwrt
      - build-csqtt-link
      - build-csqtt-link-ios
      - build-android
      - build-token-fetcher
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: release
      - name: Flatten
        run: |
          set -e
          cd release
          find . -name 'LaLune-Windows.zip' -exec cp {} ./ \;
          find . -name 'Backend-Windows.zip' -exec cp {} ./ \;
          find . -name 'Installer-Windows.zip' -exec cp {} ./ \;
          find . -name 'LaLune-Linux.zip'   -exec cp {} ./ \;
          find . -name 'Backend-Linux.zip'  -exec cp {} ./ \;
          find . -name 'lalune-openwrt-backend' -exec cp {} ./ \;
          find . -name 'LaLune-Android.apk' -exec cp {} ./ \;
          find . -name 'csqtt-link-*' -exec cp {} ./ \;
          find . -name 'csqtt_link.xcframework' -exec cp -r {} ./ \; || true
          find . -name 'libcsqtt_link.a' -exec cp {} ./ \; || true
          find . -name 'LaLuneTokenFetcher_Windows.zip' -exec cp {} ./ \;
          find . -name 'LaLuneTokenFetcher_Linux.zip'   -exec cp {} ./ \;
          ls -la
      - id: date
        run: echo "date=$(date +'%y.%m.%d.%H.%M')" >> $GITHUB_OUTPUT
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.date.outputs.date }}
          name: Release ${{ steps.date.outputs.date }}
          files: |
            release/LaLune-Windows.zip
            release/Backend-Windows.zip
            release/Installer-Windows.zip
            release/LaLune-Linux.zip
            release/Backend-Linux.zip
            release/lalune-openwrt-backend
            release/LaLune-Android.apk
            release/csqtt-link-Windows.exe
            release/csqtt-link-Linux
            release/csqtt-link-OpenWRT
            release/csqtt_link.xcframework
            release/libcsqtt_link.a
            release/LaLuneTokenFetcher_Windows.zip
            release/LaLuneTokenFetcher_Linux.zip
          fail_on_unmatched_files: false
          draft: false
          prerelease: false
          generate_release_notes: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

