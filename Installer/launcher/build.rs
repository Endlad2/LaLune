// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// build.rs — во время сборки скачивает все нужные файлы и кладёт их
// в OUT_DIR. Затем main.rs/installer.rs включают их через include_bytes!.
//
// install.ps1 больше НЕ копируется: лаунчер всё делает сам.

use anyhow::{anyhow, Context, Result};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

const URL_LALUNE_ZIP: &str =
    "https://github.com/Endlad2/LaLune/releases/latest/download/LaLune-Windows.zip";
const URL_BACKEND_ZIP: &str =
    "https://github.com/Endlad2/LaLune/releases/latest/download/Backend-Windows.zip";
const URL_CORE_EXE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/latest/download/client-windows-x86_64.exe";
const URL_LATEST: &str =
    "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
const URL_ICON: &str =
    "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/icon.ico";
const URL_WINTUN_ZIP: &str =
    "https://www.wintun.net/builds/wintun-0.14.1.zip";

fn out_dir() -> PathBuf {
    PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR not set"))
}

fn download(client: &reqwest::blocking::Client, url: &str, dest: &Path) -> Result<()> {
    if dest.exists() && dest.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        println!("cargo:warning=already present: {}", dest.display());
        return Ok(());
    }

    println!("cargo:warning=downloading: {}", url);

    let mut resp = client
        .get(url)
        .send()
        .with_context(|| format!("GET {url}"))?;

    if !resp.status().is_success() {
        return Err(anyhow!("{url}: HTTP {}", resp.status()));
    }

    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).ok();
    }

    let tmp = dest.with_extension("part");
    let mut f = fs::File::create(&tmp)
        .with_context(|| format!("create {}", tmp.display()))?;

    std::io::copy(&mut resp, &mut f)
        .with_context(|| format!("copy {url} → {}", tmp.display()))?;

    f.flush()?;
    drop(f);
    fs::rename(&tmp, dest)?;
    Ok(())
}

/// Скачивает wintun.zip и извлекает wintun\bin\amd64\wintun.dll.
fn fetch_wintun_dll(client: &reqwest::blocking::Client, out: &Path) -> Result<()> {
    let dll_dest = out.join("wintun.dll");
    if dll_dest.exists() {
        println!("cargo:warning=already present: {}", dll_dest.display());
        return Ok(());
    }

    let zip_path = out.join("wintun.zip");
    download(client, URL_WINTUN_ZIP, &zip_path)?;

    let file = fs::File::open(&zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;

    let mut found_idx: Option<usize> = None;
    for i in 0..archive.len() {
        let name = archive.by_index(i)?.name().replace('\\', "/");
        if name.ends_with("amd64/wintun.dll") {
            found_idx = Some(i);
            break;
        }
    }
    if found_idx.is_none() {
        for i in 0..archive.len() {
            let name = archive.by_index(i)?.name().replace('\\', "/");
            if name.ends_with("wintun.dll") {
                found_idx = Some(i);
                break;
            }
        }
    }

    let idx = found_idx.ok_or_else(|| anyhow!("wintun.dll not found in archive"))?;

    let mut entry = archive.by_index(idx)?;
    let mut out_file = fs::File::create(&dll_dest)?;
    std::io::copy(&mut entry, &mut out_file)?;

    println!("cargo:warning=extracted: {}", dll_dest.display());
    Ok(())
}

fn main() -> Result<()> {
    let out = out_dir();
    fs::create_dir_all(&out).ok();

    println!("cargo:rerun-if-changed=build.rs");

    let client = reqwest::blocking::Client::builder()
        .user_agent("LaLune-Installer-Build/0.6")
        .timeout(std::time::Duration::from_secs(300))
        .build()?;

    download(&client, URL_LALUNE_ZIP, &out.join("LaLune-Windows.zip"))?;
    download(&client, URL_BACKEND_ZIP, &out.join("Backend-Windows.zip"))?;
    download(&client, URL_CORE_EXE, &out.join("client-windows-x86_64.exe"))?;
    download(&client, URL_LATEST, &out.join("LATEST"))?;
    download(&client, URL_ICON, &out.join("icon.ico"))?;

    fetch_wintun_dll(&client, &out)?;

    println!("cargo:warning=LaLune installer: all resources ready in {}", out.display());
    Ok(())
}
