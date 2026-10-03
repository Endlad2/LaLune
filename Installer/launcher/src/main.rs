// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune GUI Installer для Windows.
//
// При сборке build.rs скачивает все нужные файлы и кладёт их в OUT_DIR.
// Здесь мы их включаем через include_bytes! и при нажатии «Установить»
// распаковываем в %TEMP%\.la-lune_downloader\ и запускаем install.ps1 -ci.

#![windows_subsystem = "windows"]

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use native_windows_gui as nwg;

// ==== Встроенные ресурсы (собраны build.rs) ====

static LALUNE_ZIP:  &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LaLune-Windows.zip"));
static BACKEND_ZIP: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/Backend-Windows.zip"));
static CORE_EXE:    &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/client-windows-x86_64.exe"));
static LATEST_FILE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LATEST"));
static ICON_FILE:   &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/icon.ico"));
static WINTUN_DLL:  &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/wintun.dll"));
static INSTALL_PS1: &str  = include_str!(concat!(env!("OUT_DIR"), "/install.ps1"));

// ==== Пути ====

fn temp_dir() -> PathBuf {
    let base = std::env::var("TEMP")
        .or_else(|_| std::env::var("TMP"))
        .unwrap_or_else(|_| "C:\\Windows\\Temp".to_string());
    PathBuf::from(base).join(".la-lune_downloader")
}

// ==== Распаковка ресурсов ====

fn write_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut f = fs::File::create(path)?;
    f.write_all(bytes)?;
    f.flush()?;
    Ok(())
}

/// Распаковывает zip-архив в каталог dest, перезаписывая существующие файлы.
fn unzip_overwrite(zip_bytes: &[u8], dest: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(dest)?;
    let reader = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(reader)?;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let raw_name = entry.name().replace('\\', "/");
        let name = raw_name.trim_start_matches('/');

        if name.is_empty() {
            continue;
        }

        let target = dest.join(name);

        if entry.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }

        let mut out = fs::File::create(&target)?;
        std::io::copy(&mut entry, &mut out)?;
        out.flush()?;
    }
    Ok(())
}

/// Распаковывает всё во временный каталог %TEMP%\.la-lune_downloader\
fn stage_resources() -> anyhow::Result<PathBuf> {
    let dir = temp_dir();
    fs::create_dir_all(&dir)?;

    write_file(&dir.join("LaLune-Windows.zip"), LALUNE_ZIP)?;
    write_file(&dir.join("Backend-Windows.zip"), BACKEND_ZIP)?;
    write_file(&dir.join("client-windows-x86_64.exe"), CORE_EXE)?;
    write_file(&dir.join("LATEST"), LATEST_FILE)?;
    write_file(&dir.join("icon.ico"), ICON_FILE)?;
    write_file(&dir.join("install.ps1"), INSTALL_PS1.as_bytes())?;

    // wintun.dll нужно положить в zip, потому что install.ps1 -ci
    // ожидает wintun-0.14.1.zip. Соберём его на лету.
    let wintun_zip_path = dir.join("wintun-0.14.1.zip");
    {
        let mut buf = Vec::with_capacity(WINTUN_DLL.len() + 512);
        {
            let mut zw = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
            let opts: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zw.start_file("wintun/bin/amd64/wintun.dll", opts)?;
            zw.write_all(WINTUN_DLL)?;
            zw.finish()?;
        }
        fs::write(&wintun_zip_path, &buf)?;
    }

    Ok(dir)
}

// ==== Запуск install.ps1 -ci ====

fn run_install_ps1(dir: &Path) -> std::io::Result<()> {
    let script = dir.join("install.ps1");
    let script_str = script.to_string_lossy().to_string();

    // -NoProfile        — не читать профиль юзера
    // -ExecutionPolicy Bypass — обойти политику
    // -File <script> -ci      — сам скрипт + флаг CI
    let status = Command::new("powershell")
        .args([
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", &script_str,
            "-ci",
        ])
        .current_dir(dir)
        .status()?;

    if !status.success() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("install.ps1 exited with code {:?}", status.code()),
        ));
    }
    Ok(())
}

// ==== GUI ====

struct Gui {
    window:        nwg::Window,
    label_title:   nwg::Label,
    label_desc:    nwg::Label,
    btn_install:   nwg::Button,
    btn_exit:      nwg::Button,
    label_status:  nwg::Label,
}

fn build_gui() -> Result<Gui, nwg::NwgError> {
    nwg::init()?;
    nwg::Font::set_global_family("Segoe UI").ok();

    let mut window = Default::default();
    nwg::Window::builder()
        .size((420, 240))
        .position((300, 200))
        .title("LaLune Installer")
        .flags(nwg::WindowFlags::WINDOW | nwg::WindowFlags::VISIBLE)
        .build(&mut window)?;

    let mut label_title = Default::default();
    nwg::Label::builder()
        .text("LaLune")
        .position((20, 20))
        .size((380, 30))
        .parent(&window)
        .build(&mut label_title)?;

    let mut label_desc = Default::default();
    nwg::Label::builder()
        .text("Установщик VPN-клиента LaLune.\nНажмите «Установить», чтобы продолжить.")
        .position((20, 60))
        .size((380, 60))
        .parent(&window)
        .build(&mut label_desc)?;

    let mut btn_install = Default::default();
    nwg::Button::builder()
        .text("Установить")
        .position((40, 150))
        .size((150, 40))
        .parent(&window)
        .build(&mut btn_install)?;

    let mut btn_exit = Default::default();
    nwg::Button::builder()
        .text("Выйти")
        .position((230, 150))
        .size((150, 40))
        .parent(&window)
        .build(&mut btn_exit)?;

    let mut label_status = Default::default();
    nwg::Label::builder()
        .text("")
        .position((20, 200))
        .size((380, 20))
        .parent(&window)
        .build(&mut label_status)?;

    Ok(Gui { window, label_title, label_desc, btn_install, btn_exit, label_status })
}

fn main() {
    let gui = match build_gui() {
        Ok(g) => g,
        Err(e) => {
            nwg::simple_message("LaLune Installer", &format!("Не удалось создать окно: {e}"));
            return;
        }
    };

    let handle = nwg::GlobalUI::init();

    // Обработчики кнопок
    let gui_events = nwg::full_bind_event_handler(&gui.window.handle, move |evt, evt_data, handle| {
        use nwg::Event as E;
        match evt {
            E::OnButtonClick => {
                if handle == gui.btn_exit.handle {
                    nwg::stop_thread_dispatch();
                } else if handle == gui.btn_install.handle {
                    gui.label_status.set_text("Распаковка...");
                    nwg::ModalMessageBoxSync(
                        "Установка",
                        "Начинаю установку. Это может занять несколько секунд.",
                    );

                    match stage_resources() {
                        Ok(dir) => {
                            gui.label_status.set_text("Запуск install.ps1...");
                            match run_install_ps1(&dir) {
                                Ok(_) => {
                                    nwg::simple_message(
                                        "LaLune Installer",
                                        "Установка завершена успешно!\n\n\
                                         Ярлыки LaLune добавлены на рабочий стол \
                                         и в меню Пуск.",
                                    );
                                    nwg::stop_thread_dispatch();
                                }
                                Err(e) => {
                                    nwg::simple_message(
                                        "LaLune Installer",
                                        &format!("Ошибка установки:\n{e}"),
                                    );
                                    gui.label_status.set_text("Ошибка установки.");
                                }
                            }
                        }
                        Err(e) => {
                            nwg::simple_message(
                                "LaLune Installer",
                                &format!("Ошибка распаковки:\n{e}"),
                            );
                            gui.label_status.set_text("Ошибка распаковки.");
                        }
                    }
                }
            }
            E::OnWindowClose => {
                if handle == gui.window.handle {
                    nwg::stop_thread_dispatch();
                }
            }
            _ => {}
        }
    });

    handle.join().ok();
    let _ = &gui;
}
