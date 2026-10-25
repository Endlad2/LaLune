// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// build.rs — скачивает все ресурсы в OUT_DIR перед сборкой launcher'а.
//
// wintun.zip — три источника с fallback.

use anyhow::{anyhow, bail, Context, Result};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

const URL_LALUNE_ZIP: &str =
    "https://github.com/Endlad2/LaLune/releases/latest/download/LaLune-Windows.zip";
const URL_BACKEND_ZIP: &str =
    "https://github.com/Endlad2/LaLune/releases/latest/download/Backend-Windows.zip";
const URL_CSQTT_EXE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/latest/download/client-windows-x86_64.exe";
const URL_CSQTT_219_EXE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/download/2026.09.17.17.36/client-windows-x86_64.exe";
const CSQTT_219_VERSION: &str = "2026.09.17.17.36";
const URL_CSQTTR_EXE: &str =
    "https://github.com/Endlad2/csqttr-core/releases/latest/download/client-windows-x86_64.exe";
const URL_LATEST_CSQTTR: &str =
    "https://raw.githubusercontent.com/Endlad2/csqttr-core/refs/heads/release-2.5.2/LATEST";
const URL_PAPERFLUX_EXE: &str =
    "https://github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-windows-amd64.exe";
const URL_LATEST_CSQTT: &str =
    "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
const URL_LATEST_PF: &str =
    "https://raw.githubusercontent.com/Endlad2/PaperFlux-core/refs/heads/main/LATEST";
const URL_ICON: &str =
    "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/icon.ico";

const WINTUN_SOURCES: &[&str] = &[
    "https://raw.githubusercontent.com/Endlad2/Endlad2.github.io/refs/heads/main/wintun.zip",
    "https://endlad2.github.io/wintun.zip",
    "https://www.wintun.net/builds/wintun-0.14.1.zip",
];

const MIN_PLAUSIBLE_ZIP_BYTES: u64 = 32 * 1024;

fn out_dir() -> PathBuf {
    PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR not set"))
}

fn looks_like_zip(bytes: &[u8]) -> bool {
    bytes.len() >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B
        && bytes[2] == 0x03 && bytes[3] == 0x04
}

fn download(client: &reqwest::blocking::Client, url: &str, dest: &Path) -> Result<()> {
    if dest.exists() && dest.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        println!("cargo:warning=already present: {}", dest.display());
        return Ok(());
    }
    println!("cargo:warning=downloading: {}", url);
    let mut resp = client.get(url).send().with_context(|| format!("GET {url}"))?;
    let status = resp.status();
    if !status.is_success() {
        bail!("{url}: HTTP {status}");
    }
    if let Some(parent) = dest.parent() { fs::create_dir_all(parent).ok(); }
    let tmp = dest.with_extension("part");
    let mut f = fs::File::create(&tmp)?;
    std::io::copy(&mut resp, &mut f)?;
    f.flush()?;
    drop(f);
    fs::rename(&tmp, dest)?;
    let size = fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
    println!("cargo:warning=downloaded {size} bytes");
    Ok(())
}

fn try_fetch_wintun(client: &reqwest::blocking::Client, url: &str) -> Option<Vec<u8>> {
    println!("cargo:warning=wintun: trying {}", url);
    let resp = client.get(url).send().ok()?;
    if !resp.status().is_success() { return None; }
    let bytes = resp.bytes().ok()?.to_vec();
    if (bytes.len() as u64) < MIN_PLAUSIBLE_ZIP_BYTES { return None; }
    if !looks_like_zip(&bytes) { return None; }
    println!("cargo:warning=wintun: {} → OK ({} bytes)", url, bytes.len());
    Some(bytes)
}

fn load_wintun_zip(client: &reqwest::blocking::Client) -> Result<Vec<u8>> {
    for url in WINTUN_SOURCES {
        if let Some(bytes) = try_fetch_wintun(client, url) { return Ok(bytes); }
    }
    bail!("Не удалось скачать wintun.zip ни из одного источника");
}

fn extract_wintun_dll(zip_bytes: Vec<u8>, out: &Path) -> Result<()> {
    let dll_dest = out.join("wintun.dll");
    if dll_dest.exists() { return Ok(()); }
    let reader = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(reader)?;

    let mut found_idx = None;
    for i in 0..archive.len() {
        let name = archive.by_index(i)?.name().replace('\\', "/");
        if name.ends_with("amd64/wintun.dll") { found_idx = Some(i); break; }
    }
    if found_idx.is_none() {
        for i in 0..archive.len() {
            let name = archive.by_index(i)?.name().replace('\\', "/");
            if name.ends_with("wintun.dll") { found_idx = Some(i); break; }
        }
    }

    let idx = found_idx.ok_or_else(|| anyhow!("wintun.dll не найден в архиве"))?;
    let mut entry = archive.by_index(idx)?;
    let mut out_file = fs::File::create(&dll_dest)?;
    let copied = std::io::copy(&mut entry, &mut out_file)?;
    if copied < 100_000 { bail!("Извлечённый wintun.dll подозрительно мал"); }
    println!("cargo:warning=extracted: {}", dll_dest.display());
    Ok(())
}

fn main() -> Result<()> {
    let out = out_dir();
    fs::create_dir_all(&out).ok();
    println!("cargo:rerun-if-changed=build.rs");
    let frontend_zip = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("Frontend.zip");
    println!("cargo:rerun-if-changed={}", frontend_zip.display());

    let client = reqwest::blocking::Client::builder()
        .user_agent("LaLune-Installer-Build/0.6")
        .timeout(std::time::Duration::from_secs(300))
        .build()?;

    let embedded_frontend = out.join("LaLune-Windows.zip");
    if frontend_zip.is_file() {
        println!("cargo:warning=using local Frontend.zip: {}", frontend_zip.display());
        fs::copy(&frontend_zip, &embedded_frontend)
            .with_context(|| format!("copy local Frontend.zip from {}", frontend_zip.display()))?;
    } else {
        println!("cargo:warning=Frontend.zip not found next to build.rs; downloading latest LaLune-Windows.zip");
        download(&client, URL_LALUNE_ZIP, &embedded_frontend)?;
    }
    download(&client, URL_BACKEND_ZIP, &out.join("Backend-Windows.zip"))?;
    download(&client, URL_CSQTT_EXE, &out.join("client-windows-x86_64.exe"))?;
    download(&client, URL_CSQTT_219_EXE, &out.join("csqtt-219.exe"))?;
    fs::write(out.join("LATEST.CSQTT-2.1.9"), CSQTT_219_VERSION)?;
    download(&client, URL_CSQTTR_EXE, &out.join("csqttr-windows-x86_64.exe"))?;
    download(&client, URL_LATEST_CSQTTR, &out.join("LATEST.CSQTTR"))?;
    download(&client, URL_PAPERFLUX_EXE, &out.join("paperflux-windows-amd64.exe"))?;
    download(&client, URL_LATEST_CSQTT, &out.join("LATEST.Csqtt"))?;
    download(&client, URL_LATEST_PF, &out.join("LATEST.PaperFlux"))?;
    download(&client, URL_ICON, &out.join("icon.ico"))?;

    let zip_bytes = load_wintun_zip(&client)?;
    extract_wintun_dll(zip_bytes, &out)?;

    println!("cargo:warning=LaLune installer: all resources ready");
    Ok(())
}
