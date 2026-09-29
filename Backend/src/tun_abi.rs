//! TUN C-ABI (совместимость с предыдущей версией lib.rs).

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::{Read, Write};
use std::ptr;

use tun::AbstractDevice;

pub struct LaluneTun {
    dev: tun::Device,
    name: CString,
}

#[no_mangle]
pub unsafe extern "C" fn lalune_tun_create(
    name: *const c_char,
    addr: *const c_char,
    mtu: c_int,
) -> *mut c_void {
    let name_str = if name.is_null() { String::new() }
        else { CStr::from_ptr(name).to_string_lossy().into_owned() };
    let addr_str = if addr.is_null() { String::new() }
        else { CStr::from_ptr(addr).to_string_lossy().into_owned() };

    let mut cfg = tun::Configuration::default();
    cfg.up();
    if !name_str.is_empty() { cfg.tun_name(&name_str); }
    if mtu > 0 { cfg.mtu(mtu as u16); }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        let a = if addr_str.is_empty() { "10.7.0.1" } else { addr_str.as_str() };
        cfg.address(a);
        cfg.netmask("255.255.255.0");
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        let _ = addr_str;
    }

    match tun::create(&cfg) {
        Ok(dev) => {
            let real_name = dev.tun_name().unwrap_or(name_str);
            let cname = CString::new(real_name).unwrap_or_else(|_| CString::new("tun").unwrap());
            Box::into_raw(Box::new(LaluneTun { dev, name: cname })) as *mut c_void
        }
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn lalune_tun_destroy(handle: *mut c_void) {
    if !handle.is_null() {
        drop(Box::from_raw(handle as *mut LaluneTun));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lalune_tun_read(
    handle: *mut c_void,
    buf: *mut u8,
    len: usize,
) -> isize {
    if handle.is_null() || buf.is_null() { return -1; }
    let t = &mut *(handle as *mut LaluneTun);
    let slice = std::slice::from_raw_parts_mut(buf, len);
    match t.dev.read(slice) { Ok(n) => n as isize, Err(_) => -1 }
}

#[no_mangle]
pub unsafe extern "C" fn lalune_tun_write(
    handle: *mut c_void,
    buf: *const u8,
    len: usize,
) -> isize {
    if handle.is_null() || buf.is_null() { return -1; }
    let t = &mut *(handle as *mut LaluneTun);
    let slice = std::slice::from_raw_parts(buf, len);
    match t.dev.write(slice) { Ok(n) => n as isize, Err(_) => -1 }
}

#[no_mangle]
pub unsafe extern "C" fn lalune_tun_name(
    handle: *mut c_void,
    buf: *mut c_char,
    len: usize,
) -> isize {
    if handle.is_null() || buf.is_null() || len == 0 { return -1; }
    let t = &*(handle as *mut LaluneTun);
    let bytes = t.name.as_bytes_with_nul();
    let n = bytes.len().min(len);
    ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, buf, n);
    (n - 1) as isize
}
