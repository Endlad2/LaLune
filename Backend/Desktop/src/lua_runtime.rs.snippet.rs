// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// ФРАГМЕНТ: замени метод `decode_csqtt_link` в Backend/Desktop/src/lua_runtime.rs
// на этот. Причина: E0597 "guard does not live long enough" — временный
// Result<LuaTable> из match живёт до конца функции, а guard умирает раньше.
// Решение: `let x = match ... ; x` — временный результат умер до drop(guard).

    pub fn decode_csqtt_link(&self, link: &str) -> Result<CsqttDecoded> {
        log::info!("[LUA] decode_csqtt_link: input_len={}", link.len());
        let guard = self.lua.lock();
        let package: Table = guard.globals().get("package")?;
        let loaded: Table = package.get("loaded")?;
        let module: Table = loaded
            .get("csqtt_decode")
            .map_err(|_| anyhow!("csqtt_decode module not loaded"))?;
        let parse: mlua::Function = module
            .get("parse_csqtt_link")
            .map_err(|_| anyhow!("parse_csqtt_link missing"))?;

        // let x = match ... ; x — чтобы Result<Table<'_>> умер ДО drop(guard).
        // Иначе E0597: временный Result умирает в конце блока, а guard — раньше.
        let call_result: mlua::Result<Table> = parse.call::<_, Table>(link.to_string());

        let decoded = match call_result {
            Ok(result) => {
                log::info!("[LUA] decode_csqtt_link: parse_csqtt_link returned table");
                Ok(CsqttDecoded {
                    protocol: result.get("protocol").unwrap_or_else(|_| "CSQTT".into()),
                    peer: result.get("peer").unwrap_or_default(),
                    host: result.get("host").unwrap_or_default(),
                    port: result.get("port").unwrap_or_default(),
                    password: result.get("password").unwrap_or_default(),
                    hashes: result.get("hashes").unwrap_or_default(),
                    name: result.get("name").unwrap_or_default(),
                    raw_link: result.get("raw_link").unwrap_or_else(|_| link.to_string()),
                })
            }
            Err(e) => {
                log::warn!("[LUA] decode_csqtt_link: parse_csqtt_link error: {:#}", e);
                Err(anyhow!("csqtt_decode error: {}", e))
            }
        };

        // drop(guard) неявно в конце функции, но `decoded` уже не держит borrow.
        decoded
    }
