//! LaLune native backend (Rust → C ABI).

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::ptr;
use std::sync::{Mutex, OnceLock};

mod config;
mod core_runner;
mod deploy;
mod logs;
mod net;
mod settings;
mod state;
mod token;
mod vk_api;
mod vk_launcher;

use state::AppState;

// ---------------------------------------------------------------------------
//  Глобальный state
// ---------------------------------------------------------------------------

static STATE: OnceLock<Mutex<AppState>> = OnceLock::new();

fn state() -> &'static Mutex<AppState> {
    STATE.get_or_init(|| Mutex::new(AppState::new()))
}

// ---------------------------------------------------------------------------
//  Хелперы
// ---------------------------------------------------------------------------

unsafe fn cstr_opt(p: *const c_char) -> String {
    if p.is_null() { return String::new(); }
    CStr::from_ptr(p).to_string_lossy().into_owned()
}

fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => CString::new("").unwrap().into_raw(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn lalune_free(p: *mut c_char) {
    if !p.is_null() { drop(CString::from_raw(p)); }
}

// ---------------------------------------------------------------------------
//  Init / Version
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn lalune_init() -> c_int {
    let mut st = state().lock().unwrap();
    match st.init() {
        Ok(()) => 0,
        Err(e) => { st.log(format!("[INIT] ошибка: {e}")); -1 }
    }
}

static VERSION: &[u8] = b"lalune_backend 0.2.0\0";

#[no_mangle]
pub extern "C" fn lalune_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

// ---------------------------------------------------------------------------
//  Конфиги
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn lalune_get_configs_json() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.get_configs_json())
}

#[no_mangle]
pub unsafe extern "C" fn lalune_save_config(
    link: *const c_char,
    protocol: *const c_char,
) -> c_int {
    let link = cstr_opt(link);
    let protocol = cstr_opt(protocol);
    let mut st = state().lock().unwrap();
    match st.save_config(&link, &protocol) {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[SAVE_CONFIG] ошибка: {e}")); -1 }
    }
}

#[no_mangle]
pub extern "C" fn lalune_delete_config(id: i64) -> c_int {
    let mut st = state().lock().unwrap();
    match st.delete_config(id) {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[DELETE_CONFIG] ошибка: {e}")); -1 }
    }
}

// ---------------------------------------------------------------------------
//  Настройки / Device ID / Selected config
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn lalune_get_settings_json() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.get_settings_json())
}

#[no_mangle]
pub unsafe extern "C" fn lalune_save_settings(json: *const c_char) -> c_int {
    let json = cstr_opt(json);
    let mut st = state().lock().unwrap();
    match st.save_settings(&json) {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[SAVE_SETTINGS] ошибка: {e}")); -1 }
    }
}

#[no_mangle]
pub extern "C" fn lalune_get_logs_json() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.get_logs_json())
}

#[no_mangle]
pub extern "C" fn lalune_clear_logs() -> c_int {
    let mut st = state().lock().unwrap();
    st.clear_logs();
    0
}

#[no_mangle]
pub extern "C" fn lalune_get_device_id() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.get_device_id())
}

#[no_mangle]
pub extern "C" fn lalune_regenerate_device_id() -> *mut c_char {
    let mut st = state().lock().unwrap();
    into_c_string(st.regenerate_device_id())
}

#[no_mangle]
pub unsafe extern "C" fn lalune_set_selected_config_json(json: *const c_char) -> c_int {
    let json = cstr_opt(json);
    let mut st = state().lock().unwrap();
    st.set_selected_config_json(&json);
    0
}

#[no_mangle]
pub extern "C" fn lalune_get_selected_config_json() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.get_selected_config_json())
}

// ---------------------------------------------------------------------------
//  Connect / Disconnect / Status
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn lalune_connect(id: i64) -> c_int {
    let mut st = state().lock().unwrap();
    match st.connect(id) {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[CONNECT] ошибка: {e}")); -1 }
    }
}

#[no_mangle]
pub extern "C" fn lalune_disconnect() -> c_int {
    let mut st = state().lock().unwrap();
    match st.disconnect() {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[DISCONNECT] ошибка: {e}")); -1 }
    }
}

#[no_mangle]
pub extern "C" fn lalune_get_status_json() -> *mut c_char {
    let st = state().lock().unwrap();
    let c = st.is_connected();
    into_c_string(format!("{{\"connected\":{c}}}"))
}

#[no_mangle]
pub extern "C" fn lalune_is_core_downloading() -> c_int {
    let st = state().lock().unwrap();
    if st.is_core_downloading() { 1 } else { 0 }
}

// ---------------------------------------------------------------------------
//  VK
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn lalune_get_vk_token_state_json() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.get_vk_token_state_json())
}

#[no_mangle]
pub extern "C" fn lalune_vk_login() -> c_int {
    let mut st = state().lock().unwrap();
    match st.vk_login() {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[VK_LOGIN] ошибка: {e}")); -1 }
    }
}

#[no_mangle]
pub extern "C" fn lalune_delete_vk_token() -> c_int {
    let mut st = state().lock().unwrap();
    st.delete_vk_token();
    0
}

#[no_mangle]
pub extern "C" fn lalune_validate_vk_token_json() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.get_vk_token_state_json())
}

#[no_mangle]
pub extern "C" fn lalune_run_vk_auto_api_calls() -> *mut c_char {
    let mut st = state().lock().unwrap();
    into_c_string(st.run_vk_auto_api_calls())
}

// ---------------------------------------------------------------------------
//  Updates
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn lalune_check_core_update_json() -> *mut c_char {
    let mut st = state().lock().unwrap();
    into_c_string(st.check_core_update_json())
}

#[no_mangle]
pub extern "C" fn lalune_check_lalune_update_json() -> *mut c_char {
    let mut st = state().lock().unwrap();
    into_c_string(st.check_lalune_update_json())
}

#[no_mangle]
pub extern "C" fn lalune_update_core_and_wait() -> c_int {
    let mut st = state().lock().unwrap();
    match st.update_core_and_wait() {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[UPDATE_CORE] ошибка: {e}")); -1 }
    }
}

#[no_mangle]
pub extern "C" fn lalune_open_lalune_releases() -> c_int { 0 }

#[no_mangle]
pub extern "C" fn lalune_lalune_releases_url() -> *mut c_char {
    into_c_string("https://github.com/Endlad2/LaLune/releases/latest".into())
}

// ---------------------------------------------------------------------------
//  Deploy
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn lalune_deploy_protocol(json: *const c_char) -> c_int {
    let json = cstr_opt(json);
    let mut st = state().lock().unwrap();
    match st.deploy_protocol(&json) {
        Ok(_) => 0,
        Err(e) => { st.log(format!("[DEPLOY] ошибка: {e}")); -1 }
    }
}

#[no_mangle]
pub extern "C" fn lalune_deploy_log() -> *mut c_char {
    let st = state().lock().unwrap();
    into_c_string(st.deploy_log())
}

#[no_mangle]
pub extern "C" fn lalune_is_deploying() -> c_int {
    let st = state().lock().unwrap();
    if st.is_deploying() { 1 } else { 0 }
}

// ---------------------------------------------------------------------------
//  Утилиты путей
// ---------------------------------------------------------------------------

pub(crate) fn app_dir() -> PathBuf {
    let base = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    let sub = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
            .unwrap_or_else(|| base.join("AppData").join("Roaming"))
    } else {
        base
    };
    sub.join(".la-lune")
}

pub(crate) fn configs_db_path() -> PathBuf { app_dir().join("configs.db") }
pub(crate) fn settings_path() -> PathBuf { app_dir().join("settings.json") }
pub(crate) fn token_path() -> PathBuf { app_dir().join("token.json") }
pub(crate) fn logs_path() -> PathBuf { app_dir().join("logs.txt") }
pub(crate) fn latest_path() -> PathBuf { app_dir().join("LATEST") }

pub(crate) fn core_path() -> PathBuf {
    let name = if cfg!(target_os = "windows") { "client-windows-x86_64.exe" }
               else if cfg!(target_os = "macos") { "client-macos-x86_64" }
               else { "client-linux-x86_64" };
    app_dir().join(name)
}
