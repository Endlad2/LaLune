// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// JNI-обёртка для Android.
//
// Пакет Java: com.lalune.lalune.CsqttLink
// Функции:
//   Java_com_lalune_lalune_CsqttLink_nativeParse
//   Java_com_lalune_lalune_CsqttLink_nativeDecode
//   Java_com_lalune_lalune_CsqttLink_nativeLastError
//
// Этот модуль подключается только при target_os = "android".

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use jni::objects::{JClass, JString};
use jni::sys::jstring;
use jni::JNIEnv;

use crate::{csqtt_link_decode, csqtt_link_free, csqtt_link_last_error, csqtt_link_parse};

fn new_jstring(env: &mut JNIEnv, s: String) -> jstring {
    match env.new_string(s) {
        Ok(js) => js.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_com_lalune_lalune_CsqttLink_nativeParse(
    mut env: JNIEnv,
    _class: JClass,
    link: JString,
) -> jstring {
    let link_str: String = match env.get_string(&link) {
        Ok(s) => s.into(),
        Err(_) => return std::ptr::null_mut(),
    };
    let c_link = match CString::new(link_str) {
        Ok(c) => c,
        Err(_) => return std::ptr::null_mut(),
    };
    let result_ptr = unsafe { csqtt_link_parse(c_link.as_ptr()) };
    if result_ptr.is_null() {
        return std::ptr::null_mut();
    }
    let result_str = unsafe { CStr::from_ptr(result_ptr) }
        .to_string_lossy()
        .to_string();
    unsafe { csqtt_link_free(result_ptr) };
    new_jstring(&mut env, result_str)
}

#[no_mangle]
pub extern "system" fn Java_com_lalune_lalune_CsqttLink_nativeDecode(
    mut env: JNIEnv,
    _class: JClass,
    link: JString,
) -> jstring {
    let link_str: String = match env.get_string(&link) {
        Ok(s) => s.into(),
        Err(_) => return std::ptr::null_mut(),
    };
    let c_link = match CString::new(link_str) {
        Ok(c) => c,
        Err(_) => return std::ptr::null_mut(),
    };
    let result_ptr = unsafe { csqtt_link_decode(c_link.as_ptr()) };
    if result_ptr.is_null() {
        return std::ptr::null_mut();
    }
    let result_str = unsafe { CStr::from_ptr(result_ptr) }
        .to_string_lossy()
        .to_string();
    unsafe { csqtt_link_free(result_ptr) };
    new_jstring(&mut env, result_str)
}

#[no_mangle]
pub extern "system" fn Java_com_lalune_lalune_CsqttLink_nativeLastError(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let err_ptr = unsafe { csqtt_link_last_error() };
    if err_ptr.is_null() {
        return std::ptr::null_mut();
    }
    let err_str = unsafe { CStr::from_ptr(err_ptr) }
        .to_string_lossy()
        .to_string();
    new_jstring(&mut env, err_str)
}

// Подавить unused-import warning.
#[allow(dead_code)]
fn _touch_c_char(_: *const c_char) {}
