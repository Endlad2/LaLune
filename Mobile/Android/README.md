# LaLune Android

## Сборка через GitHub Actions

Workflow `.github/workflows/build-android.yml` автоматически:

1. Скачивает бинарники ядра из `Endlad2/csqtt-core` в `jniLibs/<abi>/`
2. Собирает Universal APK (arm64-v8a + armeabi-v7a + x86_64)
3. Подписывает debug-ключом
4. Загружает APK в Artifacts и создаёт Release

## Локальная сборка

### Требования
- JDK 17
- Android SDK 34
- Gradle 8.4+

### Подготовка бинарников

```bash
mkdir -p app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}

curl -L -o app/src/main/jniLibs/arm64-v8a/libclient-android-arm64-v8a.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-arm64-v8a.so

curl -L -o app/src/main/jniLibs/armeabi-v7a/libclient-android-armeabi-v7a.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-armeabi-v7a.so

curl -L -o app/src/main/jniLibs/x86_64/libclient-android-x86_64.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-x86_64.so
```

### Сборка

```
gradle assembleRelease
```

## Архитектура

- `MainActivity.kt` — WebView UI + JS мост
- `CoreManager.kt` — запуск ядра через `Process.exec`, трёхуровневое обновление
- `LaLuneVpnService.kt` — VpnService + UDP-мост к ядру

## Логика

1. При запуске приложение проверяет ядро в `nativeLibraryDir`
2. Если нет — скачивает через прокси-фолбэки
3. При подключении запускает ядро через `Process.exec`
4. `VpnService` создаёт TUN и пробрасывает трафик через UDP
5. Логи пишутся в `files/la-lune/logs.txt`

