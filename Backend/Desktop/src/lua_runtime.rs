// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Lua-рантайм для SmartTunnel + csqtt_decode.
//
// Загружает Core/SmartTunnel.lua и Core/csqtt_decode.lua из app_dir
// (или из встроенных строк, если файлов нет).
//
// Регистрирует глобальную таблицу `smarttunnel` и модуль `zlib`.
// Вызывает on_load() при старте, on_tick() раз в секунду из tokio-таска,
// on_log(line) на каждую строку лога, on_connect()/on_disconnect() при VPN.

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use mlua::{Lua, Table, Value};
use parking_lot::Mutex;

use crate::state::AppState;

const SMARTTUNNEL_BUILTIN: &str = include_str!("../../../Core/SmartTunnel.lua");
const CSQTT_DECODE_BUILTIN: &str = include_str!("../../../Core/csqtt_decode.lua");

/// Глобальный singleton — чтобы config.rs мог достать рантайм без
/// прокидывания Arc<AppState> через всю цепочку парсинга.
static GLOBAL_LUA: OnceLock<Arc<LuaRuntime>> = OnceLock::new();

/// Возвращает глобальный LuaRuntime, если он инициализирован.
pub fn global_runtime() -> Option<Arc<LuaRuntime>> {
    GLOBAL_LUA.get().cloned()
}

pub struct LuaRuntime {
    lua: Arc<Mutex<Lua>>,
    state: Arc<AppState>,
}

impl LuaRuntime {
    pub fn new(state: Arc<AppState>) -> Result<Self> {
        let lua = Lua::new();

        register_zlib(&lua)?;

        {
            let st = lua.create_table()?;
            let f_log = lua.create_function(|_, _msg: String| Ok(()))?;
            st.set("log", f_log)?;
            lua.globals().set("smarttunnel", st)?;
        }

        let decode_path = state.app_dir.join("csqtt_decode.lua");
        let decode_src = if decode_path.exists() {
            std::fs::read_to_string(&decode_path)
                .with_context(|| format!("read {}", decode_path.display()))?
        } else {
            CSQTT_DECODE_BUILTIN.to_string()
        };

        let package: Table = lua.globals().get("package")?;
        let loaded: Table = package.get("loaded")?;
        let decode_chunk = lua.load(&decode_src).set_name("csqtt_decode");
        let decode_module: Value = decode_chunk.eval()?;
        loaded.set("csqtt_decode", decode_module)?;

        let smart_path = state.app_dir.join("SmartTunnel.lua");
        let smart_src = if smart_path.exists() {
            std::fs::read_to_string(&smart_path)
                .with_context(|| format!("read {}", smart_path.display()))?
        } else {
            SMARTTUNNEL_BUILTIN.to_string()
        };

        lua.load(&smart_src).set_name("SmartTunnel").exec()?;

        let runtime = Self {
            lua: Arc::new(Mutex::new(lua)),
            state,
        };

        runtime.install_api()?;
        runtime.call_optional::<()>("on_load", ())?;
        runtime.spawn_ticker();

        Ok(runtime)
    }

    fn install_api(&self) -> Result<()> {
        let lua_guard = self.lua.lock();
        let lua = &*lua_guard;
        let st: Table = lua.globals().get("smarttunnel")?;

        {
            let state = self.state.clone();
            let f = lua.create_function(move |_, msg: String| {
                state.log(format!("[LUA] {}", msg));
                Ok(())
            })?;
            st.set("log", f)?;
        }

        {
            let state = self.state.clone();
            let f = lua.create_function(move |lua, ()| -> mlua::Result<Table> {
                let tbl = lua.create_table()?;
                let snapshot = state.logs_snapshot();
                for (i, line) in snapshot.iter().rev().take(200).enumerate() {
                    tbl.set(i + 1, line.clone())?;
                }
                Ok(tbl)
            })?;
            st.set("logs", f)?;
        }

        {
            let state = self.state.clone();
            let f = lua.create_function(move |_, ()| -> mlua::Result<bool> {
                state.log("[LUA] smarttunnel.connect() called (noop)");
                Ok(false)
            })?;
            st.set("connect", f)?;
        }

        {
            let state = self.state.clone();
            let f = lua.create_function(move |_, ()| -> mlua::Result<bool> {
                state.log("[LUA] smarttunnel.disconnect() called (noop)");
                Ok(true)
            })?;
            st.set("disconnect", f)?;
        }

        {
            let state = self.state.clone();
            let f = lua.create_function(move |_, ()| -> mlua::Result<bool> {
                Ok(state.vpn.running.load(std::sync::atomic::Ordering::Relaxed))
            })?;
            st.set("is_connected", f)?;
        }

        {
            let state = self.state.clone();
            let f = lua.create_function(move |lua, key: String| -> mlua::Result<Value> {
                let s = state.settings.read();
                let json = serde_json::to_value(&*s).unwrap_or(serde_json::Value::Null);
                match json.get(&key) {
                    Some(serde_json::Value::String(v)) => Ok(Value::String(lua.create_string(v)?)),
                    Some(serde_json::Value::Number(n)) => {
                        if let Some(i) = n.as_i64() { Ok(Value::Integer(i)) }
                        else if let Some(f) = n.as_f64() { Ok(Value::Number(f)) }
                        else { Ok(Value::Nil) }
                    }
                    Some(serde_json::Value::Bool(b)) => Ok(Value::Boolean(*b)),
                    _ => Ok(Value::Nil),
                }
            })?;
            st.set("get_setting", f)?;
        }

        {
            let state = self.state.clone();
            let f = lua.create_function(move |_, (key, value): (String, Value)| {
                let mut s = state.settings.write();
                let json_val = match value {
                    Value::String(v) => serde_json::Value::String(v.to_str()?.to_string()),
                    Value::Integer(i) => serde_json::Value::Number(i.into()),
                    Value::Number(n) => serde_json::Number::from_f64(n)
                        .map(serde_json::Value::Number)
                        .unwrap_or(serde_json::Value::Null),
                    Value::Boolean(b) => serde_json::Value::Bool(b),
                    _ => serde_json::Value::Null,
                };
                let _ = s.set_field(&key, json_val);
                Ok(())
            })?;
            st.set("set_setting", f)?;
        }

        {
            let state = self.state.clone();
            let f = lua.create_function(move |lua, ()| -> mlua::Result<Table> {
                let tbl = lua.create_table()?;
                if let Some(token) = crate::vk::read_token(&state.app_dir) {
                    tbl.set("token", token)?;
                }
                let hashes = state.settings.read().vk_hashes.clone();
                tbl.set("hashes", hashes)?;
                tbl.set("userId", 0)?;
                tbl.set("expiresIn", 0)?;
                Ok(tbl)
            })?;
            st.set("get_vk_creds", f)?;
        }

        Ok(())
    }

    fn spawn_ticker(&self) {
        let lua = self.lua.clone();
        let state = self.state.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                if !*state.smarttunnel_running.lock() {
                    continue;
                }
                let guard = lua.lock();
                let res: mlua::Result<()> = (|| {
                    let f: Value = guard.globals().get("on_tick")?;
                    if let Value::Function(func) = f {
                        func.call::<_, ()>(())?;
                    }
                    Ok(())
                })();
                if let Err(e) = res {
                    drop(guard);
                    state.log(format!("[LUA] on_tick error: {}", e));
                }
            }
        });
    }

    /// Вызывает именованную глобальную функцию, если она определена.
    /// Аргументы — любые, реализующие `IntoLuaMulti` с произвольным
    /// временем жизни (через for<'a>).
    fn call_optional<'a, A>(&self, name: &str, args: A) -> Result<()>
    where
        A: mlua::IntoLuaMulti<'a>,
    {
        let guard = self.lua.lock();
        let globals = guard.globals();
        let f: Value = globals.get(name).context("get global")?;
        if let Value::Function(func) = f {
            func.call::<_, ()>(args)
                .with_context(|| format!("call {}", name))?;
        }
        Ok(())
    }

    pub fn on_log(&self, line: &str) {
        if !*self.state.smarttunnel_running.lock() {
            return;
        }
        let guard = self.lua.lock();
        let globals = guard.globals();
        let f: Value = match globals.get("on_log") {
            Ok(v) => v,
            Err(_) => return,
        };
        if let Value::Function(func) = f {
            let _ = func.call::<_, ()>(line.to_string());
        }
    }

    pub fn on_connect(&self) {
        let _ = self.call_optional::<()>("on_connect", ());
    }

    pub fn on_disconnect(&self) {
        let _ = self.call_optional::<()>("on_disconnect", ());
    }

    pub fn decode_csqtt_link(&self, link: &str) -> Result<CsqttDecoded> {
        let guard = self.lua.lock();
        let package: Table = guard.globals().get("package")?;
        let loaded: Table = package.get("loaded")?;
        let module: Table = loaded
            .get("csqtt_decode")
            .map_err(|_| anyhow!("csqtt_decode module not loaded"))?;
        let parse: mlua::Function = module
            .get("parse_csqtt_link")
            .map_err(|_| anyhow!("parse_csqtt_link missing"))?;

        let result: Table = parse
            .call(link.to_string())
            .map_err(|e| anyhow!("csqtt_decode error: {}", e))?;

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

    /// Выполняет произвольный Lua-код, возвращает строковое представление
    /// результата (для /debug/lua/eval).
    pub fn eval_str(&self, code: &str) -> Result<String> {
        let guard = self.lua.lock();
        let val: Value = guard
            .load(code)
            .set_name("eval")
            .eval()
            .map_err(|e| anyhow!("{}", e))?;
        Ok(format!("{:?}", val))
    }

    /// Регистрирует рантайм как глобальный singleton.
    pub fn install_global(self: Arc<Self>) {
        let _ = GLOBAL_LUA.set(self);
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CsqttDecoded {
    pub protocol: String,
    pub peer: String,
    pub host: String,
    pub port: String,
    pub password: String,
    pub hashes: String,
    pub name: String,
    pub raw_link: String,
}

fn register_zlib(lua: &Lua) -> Result<()> {
    let inflate = lua.create_function(|lua, data: mlua::String| -> mlua::Result<mlua::String> {
        use std::io::Read;
        let bytes = data.as_bytes();
        let mut decoder = flate2::read::ZlibDecoder::new(&bytes[..]);
        let mut out = Vec::new();
        decoder
            .read_to_end(&mut out)
            .map_err(|e| mlua::Error::RuntimeError(format!("inflate: {}", e)))?;
        lua.create_string(&out)
    })?;

    let zlib = lua.create_table()?;
    zlib.set("inflate", inflate)?;
    lua.globals().set("zlib", zlib.clone())?;

    let package: Table = lua.globals().get("package")?;
    let loaded: Table = package.get("loaded")?;
    loaded.set("zlib", zlib)?;

    Ok(())
}
