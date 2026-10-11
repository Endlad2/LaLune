// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// build.rs — во время сборки готовит все нужные ресурсы в OUT_DIR.
// main.rs/installer.rs включают их через include_bytes!.
//
// wintun.dll берётся ТОЛЬКО из vendor/wintun.zip — без сети.
// Если файла нет или он не zip — сборка падает с понятной
// инструкцией (см. ошибку ниже).
//
// Остальные ресурсы (LaLune-Windows.zip, Backend-Windows.zip,
// client-windows-x86_64.exe, LATEST, icon.ico) качаются как раньше
// с GitHub Releases / raw.githubusercontent.

use anyhow::{anyhow, bail, Context, Result};
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

/// Единственный источник wintun.zip — локальный vendor.
/// Никаких сетевых fallback'ов: либо файл лежит, либо сборка падает
/// с инструкцией.
const VENDOR_WINTUN: &str = "vendor/wintun.zip";

fn out_dir() -> PathBuf {
    PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR not set"))
}

fn manifest_dir() -> PathBuf {
    PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set"))
}

/// Настоящий zip начинается с сигнатуры PK\x03\x04 (0x50 0x4B 0x03 0x04).
fn looks_like_zip(bytes: &[u8]) -> bool {
    bytes.len() >= 4
        && bytes[0] == 0x50
        && bytes[1] == 0x4B
        && bytes[2] == 0x03
        && bytes[3] == 0x04
}

/// Человекопонятное описание того, что лежит в файле (HTML / zip / прочее).
fn describe_bytes(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return "пустой файл (0 байт)".to_string();
    }
    let head = &bytes[..bytes.len().min(8)];
    let head_hex: Vec<String> = head.iter().map(|b| format!("{:02X}", b)).collect();
    let head_hex = head_hex.join(" ");

    if looks_like_zip(bytes) {
        return format!("zip (PK\\x03\\x04, head={})", head_hex);
    }

    let head_ascii: String = bytes
        .iter()
        .take(80)
        .map(|&b| if (0x20..0x7F).contains(&b) { b as char } else { '.' })
        .collect();

    if head_ascii.starts_with("<!DOCTYPE") || head_ascii.starts_with("<html") {
        format!(
            "HTML, а НЕ zip (head={}). Это 404-страница, а не архив.",
            head_hex
        )
    } else {
        format!("не zip (head={}, ascii={:?})", head_hex, head_ascii)
    }
}

/// Скачивание обычного ресурса (LaLune-Windows.zip и т.п.).
/// Без проверки на zip — просто raw-байты.
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

    let status = resp.status();
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    if !status.is_success() {
        bail!("{url}: HTTP {status} (content-type: {content_type})");
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

    let size = fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
    println!(
        "cargo:warning=downloaded {size} bytes (content-type: {content_type})"
    );
    Ok(())
}

/// Читает vendor/wintun.zip. Никаких сетевых fallback'ов.
/// Если файла нет или это не zip — падает с подробной инструкцией.
fn load_vendored_wintun() -> Result<Vec<u8>> {
    let vendor_path = manifest_dir().join(VENDOR_WINTUN);

    println!(
        "cargo:warning=wintun: looking for {}",
        vendor_path.display()
    );
    println!("cargo:rerun-if-changed={}", VENDOR_WINTUN);

    if !vendor_path.exists() {
        bail!(
            "===============================\n\
             wintun.zip не найден\n\
             ===============================\n\
             \n\
             Ожидался файл:\n\
             \n\
                 {vendor}\n\
             \n\
             Его там нет. Сборка installer'а без него невозможна —\n\
             в wintun.dll лежит драйвер TUN, который использует backend.\n\
             \n\
             ЧТО СДЕЛАТЬ:\n\
             \n\
             1. Найди wintun.zip у себя на диске\n\
                (например: wintun (2).zip).\n\
             \n\
             2. Создай папку vendor/ рядом с Cargo.toml:\n\
             \n\
                 {manifest}\\vendor\\\n\
             \n\
             3. Положи туда архив и назови его ровно wintun.zip:\n\
             \n\
                 {vendor}\n\
             \n\
             4. Убедись, что внутри архива есть путь:\n\
             \n\
                 wintun/bin/amd64/wintun.dll\n\
             \n\
             5. Пересобери:\n\
             \n\
                 cd Installer\\launcher\n\
                 cargo clean\n\
                 cargo build --release\n",
            vendor = vendor_path.display(),
            manifest = manifest_dir().display(),
        );
    }

    let bytes = fs::read(&vendor_path)
        .with_context(|| format!("не могу прочитать {}", vendor_path.display()))?;

    if !looks_like_zip(&bytes) {
        bail!(
            "===============================\n\
             vendor/wintun.zip — не zip-архив\n\
             ===============================\n\
             \n\
             Файл: {vendor}\n\
             Размер: {size} байт\n\
             Содержимое: {desc}\n\
             \n\
             Что-то пошло не так при копировании. Скорее всего ты\n\
             скачал HTML-страницу вместо архива, или файл побился.\n\
             \n\
             ЧТО СДЕЛАТЬ:\n\
             \n\
             1. Заново скачай wintun с официального сайта:\n\
             \n\
                    https://www.wintun.net/\n\
             \n\
             2. Либо найди настоящий архив у себя на диске\n\
                (wintun (2).zip). Проверь, что он начинается с PK:\n\
             \n\
                    Format-Hex .\\wintun.zip | Select-Object -First 1\n\
             \n\
                Первые 4 байта должны быть 50 4B 03 04.\n\
             \n\
             3. Положи его как {vendor}\n\
             \n\
             4. Пересобери:\n\
             \n\
                    cargo clean\n\
                    cargo build --release\n",
            vendor = vendor_path.display(),
            size = bytes.len(),
            desc = describe_bytes(&bytes),
        );
    }

    println!(
        "cargo:warning=wintun: using vendored {} ({} bytes, OK)",
        vendor_path.display(),
        bytes.len()
    );
    Ok(bytes)
}

/// Извлекает wintun\bin\amd64\wintun.dll (или любую wintun.dll)
/// из zip-байтов и кладёт в OUT_DIR/wintun.dll.
fn extract_wintun_dll(zip_bytes: Vec<u8>, out: &Path) -> Result<()> {
    let dll_dest = out.join("wintun.dll");
    if dll_dest.exists() {
        println!("cargo:warning=already present: {}", dll_dest.display());
        return Ok(());
    }

    let reader = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(reader)
        .context("open vendor/wintun.zip as archive")?;

    // Ищем amd64-вариант; при неудаче — любую wintun.dll.
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

    let idx = found_idx.ok_or_else(|| {
        // Перечислим первые записи архива — это поможет отладке.
        let mut names = Vec::new();
        let vendor_path = manifest_dir().join(VENDOR_WINTUN);
        if let Ok(bytes) = fs::read(&vendor_path) {
            if let Ok(mut a) = zip::ZipArchive::new(std::io::Cursor::new(bytes)) {
                for i in 0..a.len().min(20) {
                    if let Ok(e) = a.by_index(i) {
                        names.push(e.name().to_string());
                    }
                }
            }
        }
        anyhow!(
            "wintun.dll не найден внутри {}.\n\
             Ожидался путь wintun/bin/amd64/wintun.dll.\n\
             Первые записи архива: {:?}",
            vendor_path.display(),
            names
        )
    })?;

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

    // ── 1. Стандартные ресурсы LaLune (качаются с GitHub) ──────
    download(&client, URL_LALUNE_ZIP, &out.join("LaLune-Windows.zip"))?;
    download(&client, URL_BACKEND_ZIP, &out.join("Backend-Windows.zip"))?;
    download(&client, URL_CORE_EXE, &out.join("client-windows-x86_64.exe"))?;
    download(&client, URL_LATEST, &out.join("LATEST"))?;
    download(&client, URL_ICON, &out.join("icon.ico"))?;

    // ── 2. wintun.dll из vendor/wintun.zip ──────────────────────
    let zip_bytes = load_vendored_wintun()?;
    extract_wintun_dll(zip_bytes, &out)?;

    println!(
        "cargo:warning=LaLune installer: all resources ready in {}",
        out.display()
    );
    Ok(())
}
