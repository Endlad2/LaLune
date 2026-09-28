# ⚠️ Удалите эти файлы вручную

В папке `.github/workflows/` есть старые файлы, которые нужно удалить,
иначе GitHub Actions будет ругаться и/или запускать лишние workflow:

- `build-android.yml.new`  ← старый, невалидный (расширение `.new`)
- `build-openwrt.yml`      ← OpenWRT больше не собирается в CI

Изменения в этих файлах:

```bash
git rm .github/workflows/build-android.yml.new
git rm .github/workflows/build-openwrt.yml
git commit -m "chore(ci): remove obsolete workflows"
git push
```

Либо через UI: откройте каждый файл на GitHub → значок корзины → Commit.

</BDS:create_file>

<BDS:create_file fileName=".gitignore.append">

```gitignore
# --- Android SDK/NDK (CI) ---
local.properties

# --- Rust ---
Backend/target/
Core/DeployManager/target/
OpenWRT/target/

# --- Flutter ---
Frontend/Core/.dart_tool/
Frontend/Core/build/
Frontend/Core/.flutter-plugins
Frontend/Core/.flutter-plugins-dependencies
Frontend/Core/android/.gradle/
Frontend/Core/android/local.properties
Frontend/Core/ios/Pods/
Frontend/Core/ios/.symlinks/
Frontend/Core/ios/Flutter/Flutter.framework
Frontend/Core/ios/Flutter/Flutter.podspec
Frontend/Core/ios/Flutter/Generated.xcconfig
Frontend/Core/ios/Flutter/flutter_export_environment.sh
Frontend/Core/ios/Flutter/ephemeral/
Frontend/Core/windows/flutter/ephemeral/
Frontend/Core/linux/flutter/ephemeral/

# --- C# / .NET ---
Core/LaLuneTokenFetcher/Playwright/bin/
Core/LaLuneTokenFetcher/Playwright/obj/
Core/LaLuneTokenFetcher/Libs/LaLuneTokenFetcher.Core/bin/
Core/LaLuneTokenFetcher/Libs/LaLuneTokenFetcher.Core/obj/
Core/LaLuneTokenFetcher/output/

# --- Build artifacts ---
*.zip
*.tar.gz
*.apk
*.ipa
out/
dist/

# --- OS ---
.DS_Store
Thumbs.db

