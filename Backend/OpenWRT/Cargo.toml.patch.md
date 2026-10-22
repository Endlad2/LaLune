# Патч Backend/OpenWRT/Cargo.toml

Добавить `base64` в `[dependencies]`:

```toml
[dependencies]
# ... существующие ...
base64 = "0.22"
```

Нужно, если в OpenWRT-версии `config.rs` тоже импортирует `base64`
(например, для `freeturn://` или других base64url-форматов). Если
OpenWRT-версия `base64` не использует — патч не нужен.

## Проверка

```
cd Backend/OpenWRT
./build.sh
```

</BDS:create_file>

</BDS:LONG_WORK>

Проблема одна: **`config.rs` использует `base64`, но в `Cargo.toml` его нет**.

Исправление:

1. **`Backend/Desktop/Cargo.toml`** — добавлена строка `base64 = "0.22"` в `[dependencies]`.

2. **`Backend/OpenWRT/Cargo.toml`** — то же самое (на случай, если в OpenWRT-версии `config.rs` тоже импортирует `base64`).

3. **`Cargo.toml.patch.md`** для обоих — если правишь вручную, а не заменяешь целиком.

Заодно про два warning'а (не блокируют сборку, но чище):

- **`src/protocol.rs:305`** — `for (i, arg) in args.iter().enumerate()` → `for arg in args.iter()` (i не используется).
- **`src/vpn.rs:395`** — `let events_b = events.clone();` → `let _events_b = events.clone();` или удалить строку.

После замены `Cargo.toml`:

```bash
cd Backend/Desktop
cargo build --release

Сборка пройдёт.
