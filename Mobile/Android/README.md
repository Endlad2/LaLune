# LaLune Android

## Сборка

### Требования
- Android SDK 34
- Kotlin 1.9+
- Gradle 8.0+

### Подготовка бинарников

Скачай бинарники ядра с GitHub Releases и положи их в `app/src/main/jniLibs/`:

```bash
mkdir -p app/src/main/jniLibs/arm64-v8a
mkdir -p app/src/main/jniLibs/armeabi-v7a
mkdir -p app/src/main/jniLibs/x86_64

# ARM64
curl -L -o app/src/main/jniLibs/arm64-v8a/libclient-android-arm64-v8a.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-arm64-v8a.so

# ARMv7
curl -L -o app/src/main/jniLibs/armeabi-v7a/libclient-android-armeabi-v7a.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-armeabi-v7a.so

# x86_64
curl -L -o app/src/main/jniLibs/x86_64/libclient-android-x86_64.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-x86_64.so
```

### Сборка Universal APK

```
./gradlew assembleRelease
```

APK будет содержать все три архитектуры: `arm64-v8a`, `armeabi-v7a`, `x86_64`.

## Архитектура

- `MainActivity.kt` — WebView UI + JS мост
- `CoreManager.kt` — запуск ядра через `Process.exec`
- `LaLuneVpnService.kt` — VpnService + UDP-мост

## Логика работы

1. При запуске приложение проверяет наличие ядра в `nativeLibraryDir`
2. Если ядра нет — скачивает через трёхуровневую систему (прямой → прокси → прокси+curl)
3. При подключении запускает ядро через `Process.exec` с параметрами
4. `VpnService` создаёт TUN-интерфейс и пробрасывает трафик через UDP к ядру
5. Логи ядра пишутся в `files/la-lune/logs.txt`

