# csqtt-link

CLI + библиотека для парсинга и дешифровки `csqtt://` ссылок.

## Сборка

```bash
cd Core/csqtt-link
cargo build --release
```

Появится `target/release/csqtt-link` (Windows — `csqtt-link.exe`).

## Использование CLI

```
# Полная csqtt:// ссылка (по умолчанию — расшифрованная csqtt://connect?...)
csqtt-link --url='csqtt://ABC...'
csqtt-link 'csqtt://ABC...'

# Через stdin
echo 'csqtt://ABC...' | csqtt-link

# JSON
csqtt-link --url='csqtt://ABC...' --json

# Человекочитаемые поля
csqtt-link --url='csqtt://ABC...' --format=fields

# Только query (без схемы)
csqtt-link --url='csqtt://ABC...' --format=query
```

## Как библиотека (Rust)

```
use csqtt_link::parse_csqtt_link;

let info = parse_csqtt_link("csqtt://...")?;
println!("{}", info.peer_address());
```

Добавить в `Cargo.toml`:

```
[dependencies]
csqtt-link = { path = "../Core/csqtt-link" }
```

## Как C ABI (Android / iOS)

`crate-type = ["lib", "cdylib", "staticlib"]`.

Экспортирует:

- `csqtt_link_parse(input: *const c_char) -> *mut c_char` — JSON
- `csqtt_link_decode(input: *const c_char) -> *mut c_char` — `csqtt://connect?...`
- `csqtt_link_free(ptr: *mut c_char)` — освободить строку
- `csqtt_link_last_error() -> *const c_char`
- `csqtt_link_clear_error()`

### Android

`libcsqtt_decode.so` кладётся в `jniLibs/<abi>/` и вызывается из Kotlin через JNI
(через `System.loadLibrary("csqtt_decode")` + `external fun`).

### iOS

`libcsqtt_link.a` (staticlib) линкуется в tunnel-extension и вызывается из Swift
через bridging-header.

## Формат

```
csqtt://<base64url(iv || ciphertext || tag)>
```

AES-256-GCM, ключ = SHA-256("csqtt-chiper-key"), IV = 12 байт.
Расшифрованный plaintext: `connect?v=2&host=...&peer=...&password=...&hashes=...`.

</BDS:create_file>

<BDS:create_file fileName="Core/csqtt-link/.gitignore">

```gitignore
target/
Cargo.lock

