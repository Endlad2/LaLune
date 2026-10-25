// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Логика установки (Windows, CSQTT + PaperFlux).

use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};

pub static LALUNE_ZIP:    &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LaLune-Windows.zip"));
pub static BACKEND_ZIP:   &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/Backend-Windows.zip"));
pub static CSQTT_EXE:     &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/client-windows-x86_64.exe"));
pub static CSQTT_219_EXE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/csqtt-219.exe"));
pub static CSQTTR_EXE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/csqttr-windows-x86_64.exe"));
pub static LATEST_CSQTTR: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LATEST.CSQTTR"));
pub static PAPERFLUX_EXE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/paperflux-windows-amd64.exe"));
pub static LATEST_CSQTT:  &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LATEST.Csqtt"));
pub static LATEST_CSQTT_219: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LATEST.CSQTT-2.1.9"));
pub static LATEST_PF:     &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/LATEST.PaperFlux"));
pub static ICON_FILE:     &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/icon.ico"));
pub static WINTUN_DLL:    &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/wintun.dll"));

pub fn appdata_dir() -> Result<PathBuf> {
    let base = std::env::var("APPDATA").map(PathBuf::from)
        .map_err(|_| anyhow!("APPDATA не задан"))?;
    Ok(base.join(".la-lune"))
}

pub fn app_dir() -> Result<PathBuf> { Ok(appdata_dir()?.join("app")) }

pub fn desktop_dir() -> Result<PathBuf> {
    let profile = std::env::var("USERPROFILE").map(PathBuf::from)
        .map_err(|_| anyhow!("USERPROFILE не задан"))?;
    Ok(profile.join("Desktop"))
}

pub fn start_menu_dir() -> Result<PathBuf> {
    let appdata = std::env::var("APPDATA").map(PathBuf::from)
        .map_err(|_| anyhow!("APPDATA не задан"))?;
    Ok(appdata.join("Microsoft").join("Windows").join("Start Menu").join("Programs"))
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() { fs::create_dir_all(parent)?; }
    let mut f = fs::File::create(path)?;
    f.write_all(bytes)?;
    f.flush()?;
    Ok(())
}

fn unzip_overwrite(zip_bytes: &[u8], dest: &Path) -> Result<()> {
    fs::create_dir_all(dest)?;
    let reader = Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(reader).context("ZipArchive::new")?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let raw_name = entry.name().replace('\\', "/");
        let name = raw_name.trim_start_matches('/');
        if name.is_empty() { continue; }
        let target = dest.join(name);
        if entry.is_dir() { fs::create_dir_all(&target)?; continue; }
        if let Some(parent) = target.parent() { fs::create_dir_all(parent)?; }
        let mut out = fs::File::create(&target)?;
        std::io::copy(&mut entry, &mut out)?;
    }
    Ok(())
}

#[cfg(target_os = "windows")]
mod shortcuts {
    use anyhow::{anyhow, Context, Result};
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;

    use windows::core::{Interface, PCWSTR};
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, IPersistFile,
        CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};

    fn wide(s: &OsStr) -> Vec<u16> {
        s.encode_wide().chain(std::iter::once(0)).collect()
    }

    pub fn create_shortcut(
        link_path: &Path, target_exe: &Path, icon_path: &Path, work_dir: &Path,
    ) -> Result<()> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
            let result = (|| -> Result<()> {
                let shell_link: IShellLinkW =
                    CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)
                        .context("CoCreateInstance(ShellLink)")?;
                let target_w = wide(target_exe.as_os_str());
                shell_link.SetPath(PCWSTR(target_w.as_ptr()))?;
                let work_w = wide(work_dir.as_os_str());
                shell_link.SetWorkingDirectory(PCWSTR(work_w.as_ptr()))?;
                let icon_w = wide(icon_path.as_os_str());
                shell_link.SetIconLocation(PCWSTR(icon_w.as_ptr()), 0)?;
                let desc_w = wide(OsStr::new("LaLune VPN Client"));
                shell_link.SetDescription(PCWSTR(desc_w.as_ptr()))?;

                let persist: IPersistFile = shell_link.cast().context("cast to IPersistFile")?;
                if let Some(parent) = link_path.parent() { std::fs::create_dir_all(parent)?; }
                let link_w = wide(link_path.as_os_str());
                persist.Save(PCWSTR(link_w.as_ptr()), true)
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
        _link_path: &Path, _target_exe: &Path, _icon_path: &Path, _work_dir: &Path,
    ) -> Result<()> { Ok(()) }
}

pub struct InstallReport {
    pub appdata_dir: PathBuf,
    pub app_dir: PathBuf,
    pub launcher_exe: PathBuf,
    pub desktop_link: PathBuf,
    pub start_menu_link: PathBuf,
}

pub fn run_install<F>(mut log: F) -> Result<InstallReport>
where F: FnMut(&str),
{
    let appdata = appdata_dir()?;
    let app = app_dir()?;

    log(&format!("Каталог данных: {}", appdata.display()));
    fs::create_dir_all(&appdata)?;
    fs::create_dir_all(&app)?;

    log("Распаковка LaLune-Windows.zip → app\\");
    unzip_overwrite(LALUNE_ZIP, &app)?;

    let launcher_exe = find_launcher_exe(&app)?
        .ok_or_else(|| anyhow!("LaLune.exe не найден в {}", app.display()))?;
    log(&format!("LaLune.exe: {}", launcher_exe.display()));

    log("Распаковка Backend-Windows.zip → .la-lune\\");
    unzip_overwrite(BACKEND_ZIP, &appdata)?;

    // CSQTT core
    log("Кладу CSQTT core");
    write_file(&appdata.join("csqtt-core.exe"), CSQTT_EXE)?;

    // Pinned CSQTT 2.1.9 core, kept separate from the latest CSQTT core.
    log("Кладу CSQTT 2.1.9 core");
    write_file(&appdata.join("csqtt-219.exe"), CSQTT_219_EXE)?;
    write_file(&appdata.join("LATEST.CSQTT-2.1.9"), LATEST_CSQTT_219)?;

    // CSQTTR core
    log("Кладу CSQTTR core");
    write_file(&appdata.join("csqttr-core.exe"), CSQTTR_EXE)?;
    write_file(&appdata.join("LATEST.CSQTTR"), LATEST_CSQTTR)?;

    // PaperFlux core
    log("Кладу PaperFlux core");
    write_file(&appdata.join("paperflux-core.exe"), PAPERFLUX_EXE)?;

    // LATEST
    log("Кладу LATEST.Csqtt + LATEST.CSQTT-2.1.9 + LATEST.CSQTTR + LATEST.PaperFlux");
    write_file(&appdata.join("LATEST.Csqtt"), LATEST_CSQTT)?;
    write_file(&appdata.join("LATEST.PaperFlux"), LATEST_PF)?;

    // icon + wintun
    let icon_dest = appdata.join("icon.ico");
    write_file(&icon_dest, ICON_FILE)?;
    write_file(&appdata.join("wintun.dll"), WINTUN_DLL)?;

    let desktop = desktop_dir()?.join("LaLune.lnk");
    let start_menu = start_menu_dir()?.join("LaLune.lnk");
    let work_dir = launcher_exe.parent()
        .ok_or_else(|| anyhow!("у LaLune.exe нет родительской папки"))?
        .to_path_buf();

    log(&format!("Ярлык (Desktop): {}", desktop.display()));
    shortcuts::create_shortcut(&desktop, &launcher_exe, &icon_dest, &work_dir)?;

    log(&format!("Ярлык (Start Menu): {}", start_menu.display()));
    shortcuts::create_shortcut(&start_menu, &launcher_exe, &icon_dest, &work_dir)?;

    log("Готово.");
    Ok(InstallReport {
        appdata_dir: appdata,
        app_dir: app,
        launcher_exe,
        desktop_link: desktop,
        start_menu_link: start_menu,
    })
}

fn find_launcher_exe(app: &Path) -> Result<Option<PathBuf>> {
    let direct = app.join("LaLune.exe");
    if direct.is_file() { return Ok(Some(direct)); }
    for entry in fs::read_dir(app)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            let candidate = path.join("LaLune.exe");
            if candidate.is_file() { return Ok(Some(candidate)); }
        }
    }
    Ok(None)
}
