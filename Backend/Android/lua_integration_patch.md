# Патч интеграции csqtt-link в Android

## 1. Скопировать libcsqtt_decode.so

В CI (`.github/workflows/build.yml`) после сборки `csqtt-link` под Android
скопировать `.so` в `Frontend/android/app/src/main/jniLibs/<abi>/`:

```yaml
- name: Build csqtt-link for Android
  run: |
    cd Core/csqtt-link
    rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
    # Нужен NDK в PATH (см. шаг Install NDK выше)
    cargo install cargo-ndk
    cargo ndk --target aarch64-linux-android --platform 24 -o ../../Frontend/android/app/src/main/jniLibs build --release
    cargo ndk --target armv7-linux-androideabi --platform 24 -o ../../Frontend/android/app/src/main/jniLibs build --release
    cargo ndk --target x86_64-linux-android --platform 24 -o ../../Frontend/android/app/src/main/jniLibs build --release
```

После этого в `jniLibs/<abi>/` появятся `libcsqtt_decode.so`.

## 2. Копировать CsqttLink.kt

CI уже копирует `Backend/Android/*.kt` → `Frontend/android/app/src/main/kotlin/com/lalune/lalune/`.
`CsqttLink.kt` попадёт туда автоматически.

## 3. Интеграция в Backend.kt::parseCsqtt

Заменить блок Lua-first на нативный Rust-first:

```
private fun parseCsqtt(link: String): JSONObject {
    // 1. csqtt-link (libcsqtt_decode.so) — самый надёжный.
    val json = CsqttLink.parse(link)
    if (json != null) {
        try {
            val obj = JSONObject(json)
            return JSONObject().apply {
                put("protocol", "CSQTT")
                put("peer", "${obj.optString("host")}:${obj.optInt("port")}")
                put("password", obj.optString("password"))
                val hashes = obj.optJSONArray("hashes")
                val h = StringBuilder()
                if (hashes != null) {
                    for (i in 0 until hashes.length()) {
                        if (i > 0) h.append(',')
                        h.append(hashes.getString(i))
                    }
                }
                put("hashes", h.toString())
                put("name", "${obj.optString("host")}:${obj.optInt("port")}")
                put("rawLink", link)
            }
        } catch (_: Exception) {}
    }

    // 2. Lua fallback (csqtt_decode.lua) — если пользователь положил.
    val lua = luaRuntime
    if (lua != null) {
        val decoded = lua.decodeCsqttLink(link)
        if (decoded != null) {
            return JSONObject().apply {
                put("protocol", "CSQTT")
                put("peer", decoded.peer)
                put("password", decoded.password)
                put("hashes", decoded.hashes)
                put("name", if (decoded.name.isEmpty()) decoded.peer else decoded.name)
                put("rawLink", link)
            }
        }
    }

    // 3. Нативный fallback (plain v=2).
    return parseCsqttNative(link)
}
```

Этот код можно вставить в `Backend.kt` вместо текущего `parseCsqtt`.

</BDS:create_file>

<BDS:create_file fileName="Backend/iOS/csqtt_link_bridge.h">

```c
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Мост к Core/csqtt-link (staticlib) для iOS.
// Линкуется в LaLuneTunnel extension.

#ifndef CSQTT_LINK_BRIDGE_H
#define CSQTT_LINK_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Парсит csqtt:// ссылку, возвращает JSON-строку (malloc).
// Освобождать через csqtt_link_free.
char* csqtt_link_parse(const char* input);

// Возвращает csqtt://connect?... (malloc). Освобождать через csqtt_link_free.
char* csqtt_link_decode(const char* input);

// Освобождает строку, возвращённую выше.
void csqtt_link_free(char* ptr);

// Последняя ошибка (thread-local).
const char* csqtt_link_last_error(void);
void csqtt_link_clear_error(void);

#ifdef __cplusplus
}
#endif

#endif

