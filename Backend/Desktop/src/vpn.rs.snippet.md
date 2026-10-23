# Фикс warning в vpn.rs

В `Backend/Desktop/src/vpn.rs`, строка 394:

```rust
// было:
let events_b = events.clone();

// стало (если events_b не используется):
let _events_b = events.clone();

// или (если используется):
// оставить как есть — это warning, не ошибка
```

Warning `unused variable: events_b` не блокирует сборку. Если не хочешь
разбираться — проигнорируй, `cargo build --release` пройдёт.

</BDS:create_file>
</BDS:LONG_WORK>

Готово. В zip:

**`Backend/Desktop/src/lua_runtime.rs`** — полный файл. В `decode_csqtt_link` теперь:

```rust
let guard = self.lua.lock();

// Borrow'ы ограничены блоком { ... }, module/loaded/package умирают сразу.
let parse: mlua::Function = {
    let package: Table = guard.globals().get("package")?;
    let loaded: Table = package.get("loaded")?;
    let module: Table = loaded.get("csqtt_decode")...?;
    module.get("parse_csqtt_link")...?
};

// Ключевая строка — let, чтобы временный Result<Table<'_>> умер ЗДЕСЬ.
let call_result: mlua::Result<Table> = parse.call::<_, Table>(link.to_string());

let decoded: Result<CsqttDecoded> = match call_result { Ok(result) => { ... }, Err(e) => { ... } };

drop(guard);
decoded

Ты, видимо, вставил только `let x = match ...; x`-фрагмент, но **не заменил** остальные `let package/loaded/module/parse` — они всё ещё держат borrow `guard` и живут до конца функции. Полная версия разбивает их на отдельные блоки + `drop(guard)` перед `decoded`.

**`Backend/Desktop/src/vpn.rs.snippet.md`** — warning `events_b` не критичен, можно оставить или переименовать в `_events_b`.

Замени `lua_runtime.rs` целиком (не вставляй фрагменты) — и `cargo run` пройдёт.
