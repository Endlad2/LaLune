// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// wintun.rs — FFI к wintun.dll (Windows-only).
//
// Порт логики из старой Go-версии (Desktop/Windows/app_windows.go):
//   * WintunOpenAdapter("CSQTT") → если нет, WintunCreateAdapter("CSQTT","Wintun")
//   * WintunStartSession(adapter, 0x400000) — ring 4 МБ
//   * WintunReceivePacket / WintunReleaseReceivePacket
//   * WintunAllocateSendPacket / WintunSendPacket
//
// DLL загружается из %APPDATA%\.la-lune\wintun.dll.
// Адаптер "CSQTT" создаёт сам бэкенд; ядро CSQTT его не трогает —
// оно читает/пишет UDP на 127.0.0.1:52230, а мост гоняет пакеты
// между ring-buffer'ом Wintun и UDP-сокетом.
//
// ВАЖНО: этот модуль компилируется только на Windows.
// На не-Windows возвращает ошибку при вызове.

#![cfg(target_os = "windows")]

use anyhow::{anyhow, Result};
use std::ffi::{c_void, OsStr};
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::sync::Arc;

use libloading::{Library, Symbol};
use parking_lot::Mutex;

// ============================================================
//  Типы WinAPI (не тянем windows-sys ради 6 функций)
// ============================================================

type Handle = *mut c_void;
type Bool = i32;

#[repr(C)]
pub struct Guid {
    pub data1: u32,
    pub data2: u16,
    pub data3: u16,
    pub data4: [u8; 8],
}

#[repr(C)]
pub struct Luid {
    pub low_part: u32,
    pub high_part: i32,
}

// ============================================================
//  Сигнатуры функций wintun.dll
//
//  WINTUN_CREATE_ADAPTER_FUNC      WintunCreateAdapter
//  WINTUN_OPEN_ADAPTER_FUNC        WintunOpenAdapter
//  WINTUN_CLOSE_ADAPTER_FUNC       WintunCloseAdapter
//  WINTUN_START_SESSION_FUNC       WintunStartSession
//  WINTUN_END_SESSION_FUNC         WintunEndSession
//  WINTUN_RECEIVE_PACKET_FUNC      WintunReceivePacket
//  WINTUN_RELEASE_RECEIVE_PACKET   WintunReleaseReceivePacket
//  WINTUN_ALLOCATE_SEND_PACKET     WintunAllocateSendPacket
//  WINTUN_SEND_PACKET              WintunSendPacket
// ============================================================

type FnCreateAdapter = unsafe extern "system" fn(
    name: *const u16,
    tunnel_type: *const u16,
    requested_guid: *const Guid,
) -> Handle;

type FnOpenAdapter = unsafe extern "system" fn(name: *const u16) -> Handle;

type FnCloseAdapter = unsafe extern "system" fn(adapter: Handle);

type FnStartSession =
    unsafe extern "system" fn(adapter: Handle, capacity: u32) -> Handle;

type FnEndSession = unsafe extern "system" fn(session: Handle);

type FnReceivePacket =
    unsafe extern "system" fn(session: Handle, packet_size: *mut u32) -> *mut u8;

type FnReleaseReceivePacket =
    unsafe extern "system" fn(session: Handle, packet: *const u8);

type FnAllocateSendPacket =
    unsafe extern "system" fn(session: Handle, packet_size: u32) -> *mut u8;

type FnSendPacket = unsafe extern "system" fn(session: Handle, packet: *const u8);

// ============================================================
//  WintunDll — загруженная библиотека + все процедуры
// ============================================================

struct WintunDll {
    _lib: Library,

    create_adapter: FnCreateAdapter,
    open_adapter: FnOpenAdapter,
    close_adapter: FnCloseAdapter,
    start_session: FnStartSession,
    end_session: FnEndSession,
    receive_packet: FnReceivePacket,
    release_receive_packet: FnReleaseReceivePacket,
    allocate_send_packet: FnAllocateSendPacket,
    send_packet: FnSendPacket,
}

// SAFETY: все функции wintun.dll thread-safe на уровне API:
// ReceivePacket и SendPacket спокойно вызываются из разных потоков
// при работе с одной сессией (это подтверждено доками wintun.net).
unsafe impl Send for WintunDll {}
unsafe impl Sync for WintunDll {}

impl WintunDll {
    fn load(dll_path: &Path) -> Result<Arc<Self>> {
        if !dll_path.exists() {
            return Err(anyhow!(
                "wintun.dll не найден по пути {}. Положите его в %APPDATA%\\.la-lune\\ вручную.",
                dll_path.display()
            ));
        }

        let lib = unsafe { Library::new(dll_path) }.map_err(|e| {
            anyhow!(
                "не удалось загрузить {}: {}",
                dll_path.display(),
                e
            )
        })?;

        // Безопасно: символы существуют во всех версиях wintun >= 0.14.
        unsafe {
            let create_adapter: Symbol<FnCreateAdapter> =
                lib.get(b"WintunCreateAdapter\0")?;
            let open_adapter: Symbol<FnOpenAdapter> =
                lib.get(b"WintunOpenAdapter\0")?;
            let close_adapter: Symbol<FnCloseAdapter> =
                lib.get(b"WintunCloseAdapter\0")?;
            let start_session: Symbol<FnStartSession> =
                lib.get(b"WintunStartSession\0")?;
            let end_session: Symbol<FnEndSession> =
                lib.get(b"WintunEndSession\0")?;
            let receive_packet: Symbol<FnReceivePacket> =
                lib.get(b"WintunReceivePacket\0")?;
            let release_receive_packet: Symbol<FnReleaseReceivePacket> =
                lib.get(b"WintunReleaseReceivePacket\0")?;
            let allocate_send_packet: Symbol<FnAllocateSendPacket> =
                lib.get(b"WintunAllocateSendPacket\0")?;
            let send_packet: Symbol<FnSendPacket> =
                lib.get(b"WintunSendPacket\0")?;

            Ok(Arc::new(WintunDll {
                create_adapter: *create_adapter,
                open_adapter: *open_adapter,
                close_adapter: *close_adapter,
                start_session: *start_session,
                end_session: *end_session,
                receive_packet: *receive_packet,
                release_receive_packet: *release_receive_packet,
                allocate_send_packet: *allocate_send_packet,
                send_packet: *send_packet,
                _lib: lib,
            }))
        }
    }
}

// ============================================================
//  UTF-16 helper
// ============================================================

fn to_utf16(s: &str) -> Vec<u16> {
    OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

// ============================================================
//  WintunSession — публичный интерфейс
// ============================================================

/// Сессия Wintun поверх адаптера "CSQTT".
///
/// Методы `receive_packet()` и `send_packet()` можно вызывать из разных
/// потоков — внутренние вызовы wintun.dll thread-safe.
pub struct WintunSession {
    dll: Arc<WintunDll>,
    adapter: Handle,
    session: Handle,
    adapter_name: String,
}

// SAFETY: см. комментарий к WintunDll.
unsafe impl Send for WintunSession {}
unsafe impl Sync for WintunSession {}

/// Ring-buffer capacity: 4 МБ, как в старом Go-коде.
pub const WINTUN_RING_CAPACITY: u32 = 0x400000;

/// Имя адаптера — фиксированное, к нему прибиты netsh-команды.
pub const WINTUN_ADAPTER_NAME: &str = "CSQTT";

impl WintunSession {
    /// Загружает wintun.dll из указанного пути и открывает (или создаёт)
    /// адаптер `CSQTT`, поверх которого поднимает сессию.
    pub fn open_or_create(dll_path: &Path) -> Result<Self> {
        let dll = WintunDll::load(dll_path)?;

        let name_u16 = to_utf16(WINTUN_ADAPTER_NAME);

        // 1) Пытаемся открыть существующий адаптер.
        let mut adapter = unsafe { (dll.open_adapter)(name_u16.as_ptr()) };

        if adapter.is_null() {
            log::info!(
                "[WINTUN] адаптер {} не найден, создаю новый",
                WINTUN_ADAPTER_NAME
            );
            let tunnel_type_u16 = to_utf16("Wintun");
            adapter = unsafe {
                (dll.create_adapter)(
                    name_u16.as_ptr(),
                    tunnel_type_u16.as_ptr(),
                    std::ptr::null(),
                )
            };
        } else {
            log::info!(
                "[WINTUN] адаптер {} уже существует, переоткрываю",
                WINTUN_ADAPTER_NAME
            );
        }

        if adapter.is_null() {
            return Err(anyhow!(
                "WintunOpenAdapter/WintunCreateAdapter вернул NULL — \
                 нет прав администратора или адаптер занят"
            ));
        }

        // 2) Поднимаем сессию с ring-buffer'ом 4 МБ.
        let session = unsafe { (dll.start_session)(adapter, WINTUN_RING_CAPACITY) };
        if session.is_null() {
            unsafe { (dll.close_adapter)(adapter) };
            return Err(anyhow!(
                "WintunStartSession вернул NULL — не удалось поднять ring-buffer"
            ));
        }

        log::info!(
            "[WINTUN] сессия открыта: adapter={}, ring={} bytes",
            WINTUN_ADAPTER_NAME,
            WINTUN_RING_CAPACITY
        );

        Ok(Self {
            dll,
            adapter,
            session,
            adapter_name: WINTUN_ADAPTER_NAME.to_string(),
        })
    }

    pub fn adapter_name(&self) -> &str {
        &self.adapter_name
    }

    /// Забрать один пакет из ring-buffer'а. Возвращает None, если
    /// пакетов нет прямо сейчас (не ошибка — надо просто повторить).
    ///
    /// **ОЧЕНЬ ВАЖНО:** после обработки пакета обязательно вызвать
    /// `release_packet(packet_ptr)`. Иначе ring-buffer забьётся и
    /// Wintun перестанет принимать пакеты от ОС.
    pub fn receive_packet(&self) -> Option<(*const u8, u32)> {
        let mut size: u32 = 0;
        let ptr = unsafe { (self.dll.receive_packet)(self.session, &mut size) };
        if ptr.is_null() || size == 0 {
            None
        } else {
            Some((ptr as *const u8, size))
        }
    }

    /// Освободить пакет, полученный из `receive_packet()`.
    pub fn release_packet(&self, ptr: *const u8) {
        unsafe { (self.dll.release_receive_packet)(self.session, ptr) };
    }

    /// Скопировать срез в ring-buffer и отправить его в стек ОС.
    /// Возвращает Err, если ring переполнен (надо ретраить) или DLL
    /// вернула NULL.
    pub fn send_packet(&self, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }

        let size = data.len() as u32;
        let dst = unsafe { (self.dll.allocate_send_packet)(self.session, size) };
        if dst.is_null() {
            return Err(anyhow!("WintunAllocateSendPacket вернул NULL (ring полон?)"));
        }

        // Копируем только один раз: из нашего среза в ring Wintun.
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr(), dst, data.len());
        }

        unsafe { (self.dll.send_packet)(self.session, dst) };
        Ok(())
    }

    /// Прочитать пакет из ring-buffer'а в переданный буфер.
    /// Возвращает размер скопированных данных или 0, если пакетов нет.
    ///
    /// После возврата ≥ 1 внутренний ring-пакет освобождается автоматически.
    pub fn recv_into(&self, buf: &mut [u8]) -> usize {
        match self.receive_packet() {
            Some((ptr, size)) => {
                let n = (size as usize).min(buf.len());
                unsafe {
                    std::ptr::copy_nonoverlapping(ptr, buf.as_mut_ptr(), n);
                    self.release_packet(ptr);
                }
                n
            }
            None => 0,
        }
    }
}

impl Drop for WintunSession {
    fn drop(&mut self) {
        // Порядок: сначала сессия, потом адаптер.
        unsafe {
            if !self.session.is_null() {
                (self.dll.end_session)(self.session);
                self.session = std::ptr::null_mut();
            }
            if !self.adapter.is_null() {
                (self.dll.close_adapter)(self.adapter);
                self.adapter = std::ptr::null_mut();
            }
        }
        log::info!("[WINTUN] сессия и адаптер закрыты");
    }
}

// ============================================================
//  Публичный контейнер для одной сессии в vpn runtime
//
//  Используется в VpnRuntime: пока VPN поднят — здесь лежит
//  WintunSession. На disconnect() — дропается, закрывая всё.
// ============================================================

pub type SharedWintunSession = Arc<Mutex<Option<WintunSession>>>;

pub fn new_shared_session() -> SharedWintunSession {
    Arc::new(Mutex::new(None))
}
