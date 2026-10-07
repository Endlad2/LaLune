// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Вся логика установки — на чистом Rust. Никаких .ps1-скриптов.
//
// Что делает:
//   1. Создаёт %APPDATA%\.la-lune\ и %APPDATA%\.la-lune\app\.
//   2. Распаковывает встроенные zip-архивы:
//        LaLune-Windows.zip  → %APPDATA%\.la-lune\app\
//        Backend-Windows.zip → %APPDATA%\.la-lune\
//   3. Кладёт файлы из ресурсов:
//        client-windows-x86_64.exe → %APPDATA%\.la-lune\client-windows-x86_64.exe
//        LATEST                    → %APPDATA%\.la-lune\LATEST
//        icon.ico                  → %APPDATA%\.la-lune\icon.ico
//        wintun.dll                → %APPDATA%\.la-lune\wintun.dll
//   4. Создаёт ярлыки:
//        %USERPROFILE%\Desktop\LaLune.lnk
//        %APPDATA%\Microsoft\Windows\Start Menu\Programs\LaLune.lnk
//      (через COM IShellLink / IPersistFile)
//   5. Возвращает путь к установленному LaLune.exe.

use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};

// ============================================================
//  Встроенные ресурсы (наполняются build.rs)
// ============================================================

pub static LALUNE_ZIP:  &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LaLune-Windows.zip"));
pub static BACKEND_ZIP: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/Backend-Windows.zip"));
pub static CORE_EXE:    &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/client-windows-x86_64.exe"));
pub static LATEST_FILE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LATEST"));
pub static ICON_FILE:   &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/icon.ico"));
pub static WINTUN_DLL:  &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/wintun.dll"));

// ============================================================
//  Пути
// ============================================================

pub fn appdata_dir() -> Result<PathBuf> {
    let base = std::env::var("APPDATA")
        .map(PathBuf::from)
        .map_err(|_| anyhow!("APPDATA не задан"))?;
    Ok(base.join(".la-lune"))
}

pub fn app_dir() -> Result<PathBuf> {
    Ok(appdata_dir()?.join("app"))
}

pub fn desktop_dir() -> Result<PathBuf> {
    // %USERPROFILE%\Desktop — самый совместимый вариант.
    // (SHGetKnownFolderPath тоже работает, но требует windows-крейт,
    //  который у нас уже есть для ярлыков.)
    let profile = std::env::var("USERPROFILE")
        .map(PathBuf::from)
        .map_err(|_| anyhow!("USERPROFILE не задан"))?;
    Ok(profile.join("Desktop"))
}

pub fn start_menu_dir() -> Result<PathBuf> {
    let appdata = std::env::var("APPDATA")
        .map(PathBuf::from)
        .map_err(|_| anyhow!("APPDATA не задан"))?;
    Ok(appdata
        .join("Microsoft")
        .join("Windows")
        .join("Start Menu")
        .join("Programs"))
}

// ============================================================
//  Утилиты
// ============================================================

fn write_file(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create_dir_all {}", parent.display()))?;
    }
    let mut f = fs::File::create(path)
        .with_context(|| format!("create {}", path.display()))?;
    f.write_all(bytes)?;
    f.flush()?;
    Ok(())
}

/// Распаковка zip-архива в каталог dest с перезаписью файлов.
fn unzip_overwrite(zip_bytes: &[u8], dest: &Path) -> Result<()> {
    fs::create_dir_all(dest)
        .with_context(|| format!("create_dir_all {}", dest.display()))?;

    let reader = Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(reader)
        .context("ZipArchive::new")?;

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

        let mut out = fs::File::create(&target)
            .with_context(|| format!("create {}", target.display()))?;
        std::io::copy(&mut entry, &mut out)?;
        out.flush()?;
    }
    Ok(())
}

// ============================================================
//  Ярлыки (COM: IShellLink + IPersistFile)
// ============================================================

#[cfg(target_os = "windows")]
mod shortcuts {
    use anyhow::{anyhow, Context, Result};
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;

    use windows::core::{Interface, PCWSTR};
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize,
        CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::UI::Shell::{
        IShellLinkW, ShellLink, IPersistFile,
    };

    fn wide(s: &OsStr) -> Vec<u16> {
        s.encode_wide().chain(std::iter::once(0)).collect()
    }

    /// Создаёт .lnk-ярлык.
    ///
    /// link_path  — куда положить .lnk
    /// target_exe — на что указывает ярлык
    /// icon_path  — .ico-файл для иконки
    /// work_dir   — рабочая директория (обычно = parent target_exe)
    pub fn create_shortcut(
        link_path: &Path,
        target_exe: &Path,
        icon_path: &Path,
        work_dir: &Path,
    ) -> Result<()> {
        unsafe {
            // COM init — может уже быть инициализирован, это ок.
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);

            let result = (|| -> Result<()> {
                let shell_link: IShellLinkW =
                    CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)
                        .context("CoCreateInstance(ShellLink)")?;

                let target_w = wide(target_exe.as_os_str());
                shell_link
                    .SetPath(PCWSTR(target_w.as_ptr()))
                    .context("SetPath")?;

                let work_w = wide(work_dir.as_os_str());
                shell_link
                    .SetWorkingDirectory(PCWSTR(work_w.as_ptr()))
                    .context("SetWorkingDirectory")?;

                let icon_w = wide(icon_path.as_os_str());
                shell_link
                    .SetIconLocation(PCWSTR(icon_w.as_ptr()), 0)
                    .context("SetIconLocation")?;

                let desc_w = wide(OsStr::new("LaLune VPN Client"));
                shell_link
                    .SetDescription(PCWSTR(desc_w.as_ptr()))
                    .context("SetDescription")?;

                // IPersistFile::Save
                let persist: IPersistFile = shell_link
                    .cast()
                    .context("cast to IPersistFile")?;

                if let Some(parent) = link_path.parent() {
                    std::fs::create_dir_all(parent)?;
                }

                let link_w = wide(link_path.as_os_str());
                persist
                    .Save(PCWSTR(link_w.as_ptr()), true)
                    .map_err(|e| anyhow!("IPersistFile::Save failed: {e}"))?;

                Ok(())
            })();

            CoUninitialize();
            result
        }
    }
}

#[cfg(not(target_os = "windows"))]
mod shortcuts {
    use anyhow::Result;
    use std::path::Path;

    pub fn create_shortcut(
        _link_path: &Path,
        _target_exe: &Path,
        _icon_path: &Path,
        _work_dir: &Path,
    ) -> Result<()> {
        Ok(())
    }
}

// ============================================================
//  Главный сценарий
// ============================================================

pub struct InstallReport {
    pub appdata_dir: PathBuf,
    pub app_dir: PathBuf,
    pub launcher_exe: PathBuf,
    pub desktop_link: PathBuf,
    pub start_menu_link: PathBuf,
}

pub fn run_install<F>(mut log: F) -> Result<InstallReport>
where
    F: FnMut(&str),
{
    // ---------- 1. Пути ----------
    let appdata = appdata_dir()?;
    let app = app_dir()?;

    log(&format!("Каталог данных: {}", appdata.display()));

    fs::create_dir_all(&appdata)
        .with_context(|| format!("create {}", appdata.display()))?;
    fs::create_dir_all(&app)
        .with_context(|| format!("create {}", app.display()))?;

    // ---------- 2. Распаковка LaLune-Windows.zip → app\ ----------
    log("Распаковка LaLune-Windows.zip → app\\");
    unzip_overwrite(LALUNE_ZIP, &app)
        .context("не удалось распаковать LaLune-Windows.zip")?;

    // Ищем LaLune.exe (может лежать как в корне app\, так и в подпапке).
    let launcher_exe = find_launcher_exe(&app)?
        .ok_or_else(|| anyhow!(
            "LaLune.exe не найден в {} после распаковки", app.display()
        ))?;
    log(&format!("LaLune.exe: {}", launcher_exe.display()));

    // ---------- 3. Распаковка Backend-Windows.zip → %APPDATA%\.la-lune\ ----------
    log("Распаковка Backend-Windows.zip → .la-lune\\");
    unzip_overwrite(BACKEND_ZIP, &appdata)
        .context("не удалось распаковать Backend-Windows.zip")?;

    // ---------- 4. Ядро CSQTT ----------
    let core_dest = appdata.join("client-windows-x86_64.exe");
    log(&format!("Ядро → {}", core_dest.display()));
    write_file(&core_dest, CORE_EXE)?;

    // ---------- 5. LATEST ----------
    let latest_dest = appdata.join("LATEST");
    log(&format!("LATEST → {}", latest_dest.display()));
    write_file(&latest_dest, LATEST_FILE)?;

    // ---------- 6. icon.ico ----------
    let icon_dest = appdata.join("icon.ico");
    log(&format!("Иконка → {}", icon_dest.display()));
    write_file(&icon_dest, ICON_FILE)?;

    // ---------- 7. wintun.dll ----------
    let wintun_dest = appdata.join("wintun.dll");
    log(&format!("Wintun → {}", wintun_dest.display()));
    write_file(&wintun_dest, WINTUN_DLL)?;

    // ---------- 8. Ярлыки ----------
    let desktop = desktop_dir()
        .context("не удалось определить Desktop")?
        .join("LaLune.lnk");

    let start_menu = start_menu_dir()
        .context("не удалось определить Start Menu")?
        .join("LaLune.lnk");

    let work_dir = launcher_exe
        .parent()
        .ok_or_else(|| anyhow!("у LaLune.exe нет родительской папки"))?
        .to_path_buf();

    log(&format!("Ярлык (Desktop): {}", desktop.display()));
    shortcuts::create_shortcut(&desktop, &launcher_exe, &icon_dest, &work_dir)
        .context("не удалось создать ярлык на рабочем столе")?;

    log(&format!("Ярлык (Start Menu): {}", start_menu.display()));
    shortcuts::create_shortcut(&start_menu, &launcher_exe, &icon_dest, &work_dir)
        .context("не удалось создать ярлык в меню Пуск")?;

    log("Готово.");

    Ok(InstallReport {
        appdata_dir: appdata,
        app_dir: app,
        launcher_exe,
        desktop_link: desktop,
        start_menu_link: start_menu,
    })
}

/// Ищет LaLune.exe в каталоге app\ (в корне или на 1 уровень вглубь).
fn find_launcher_exe(app: &Path) -> Result<Option<PathBuf>> {
    // 1. Прямо в корне
    let direct = app.join("LaLune.exe");
    if direct.is_file() {
        return Ok(Some(direct));
    }
    // 2. На один уровень вглубь (иногда zip содержит подпапку)
    for entry in fs::read_dir(app)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            let candidate = path.join("LaLune.exe");
            if candidate.is_file() {
                return Ok(Some(candidate));
            }
        }
    }
    Ok(None)
}
