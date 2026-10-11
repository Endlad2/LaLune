// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// build.rs — во время сборки готовит все нужные ресурсы в OUT_DIR.
// main.rs/installer.rs включают их через include_bytes!.
//
// wintun.zip скачивается по ТРЁМ источникам (f allback'и):
//
//   1. raw.githubusercontent.com/Endlad2/Endlad2.github.io/refs/heads/main/wintun.zip
//   2. endlad2.github.io/wintun.zip
//   3. www.wintun.net/builds/wintun-0.14.1.zip
//
// На каждом шаге проверяется сигнатура PK\x03\x04. Если источник
// вернул HTML/404 — идём к следующему. Никакого vendor/.

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

/// Три источника wintun.zip в порядке приоритета.
const WINTUN_SOURCES: &[&str] = &[
    // 1. raw.githubusercontent — отдаёт файл как есть, без Pages-магии.
    "https://raw.githubusercontent.com/Endlad2/Endlad2.github.io/refs/heads/main/wintun.zip",
    // 2. GitHub Pages.
    "https://endlad2.github.io/wintun.zip",
    // 3. Официальный сайт wintun.
    "https://www.wintun.net/builds/wintun-0.14.1.zip",
];

/// Минимальный разумный размер zip с wintun.dll (~370 KB).
/// Всё, что меньше — почти наверняка HTML (8192 байта).
const MIN_PLAUSIBLE_ZIP_BYTES: u64 = 32 * 1024;

fn out_dir() -> PathBuf {
    PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR not set"))
}

/// Настоящий zip начинается с сигнатуры PK\x03\x04 (0x50 0x4B 0x03 0x04).
fn looks_like_zip(bytes: &[u8]) -> bool {
    bytes.len() >= 4
        && bytes[0] == 0x50
        && bytes[1] == 0x4B
        && bytes[2] == 0x03
        && bytes[3] == 0x04
}

/// Короткое описание содержимого для логов и ошибок.
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
        format!("HTML, а НЕ zip (head={})", head_hex)
    } else {
        format!("не zip (head={}, ascii={:?})", head_hex, head_ascii)
    }
}

/// Перечисляет записи zip-архива (до `limit`) — для сообщений об ошибках.
fn list_zip_entries(zip_bytes: &[u8], limit: usize) -> String {
    use std::io::Cursor;

    let reader = Cursor::new(zip_bytes);
    let mut archive = match zip::ZipArchive::new(reader) {
        Ok(a) => a,
        Err(e) => return format!("  <не удалось открыть архив: {}>\n", e),
    };

    let total = archive.len();
    let mut out = String::new();
    for i in 0..total.min(limit) {
        match archive.by_index(i) {
            Ok(entry) => {
                let name = entry.name().replace('\\', "/");
                out.push_str(&format!("  [{}] {} ({} bytes)\n", i, name, entry.size()));
            }
            Err(e) => {
                out.push_str(&format!("  [{}] <ошибка чтения: {}>\n", i, e));
            }
        }
    }
    if total > limit {
        out.push_str(&format!("  ... и ещё {} записей\n", total - limit));
    }
    if total == 0 {
        out.push_str("  <архив пустой>\n");
    }
    out
}

/// Обычное скачивание обычного ресурса (LaLune-Windows.zip и т.п.).
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

/// Скачивает wintun.zip по одному URL в память и возвращает байты,
/// ЕСЛИ это валидный zip. Иначе — печатает причину и возвращает None.
fn try_fetch_wintun_zip(
    client: &reqwest::blocking::Client,
    url: &str,
) -> Option<Vec<u8>> {
    println!("cargo:warning=wintun: trying {}", url);

    let resp = match client.get(url).send() {
        Ok(r) => r,
        Err(e) => {
            println!("cargo:warning=wintun: {} → request error: {}", url, e);
            return None;
        }
    };

    let status = resp.status();
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    if !status.is_success() {
        println!(
            "cargo:warning=wintun: {} → HTTP {} (content-type: {})",
            url, status, content_type
        );
        return None;
    }

    let bytes = match resp.bytes() {
        Ok(b) => b.to_vec(),
        Err(e) => {
            println!("cargo:warning=wintun: {} → read error: {}", url, e);
            return None;
        }
    };

    // Проверка размера ДО сигнатуры — быстрее и понятнее.
    if (bytes.len() as u64) < MIN_PLAUSIBLE_ZIP_BYTES {
        println!(
            "cargo:warning=wintun: {} → too small ({} bytes) — {}",
            url,
            bytes.len(),
            describe_bytes(&bytes)
        );
        return None;
    }

    if !looks_like_zip(&bytes) {
        println!(
            "cargo:warning=wintun: {} → not a zip ({} bytes) — {}",
            url,
            bytes.len(),
            describe_bytes(&bytes)
        );
        return None;
    }

    println!(
        "cargo:warning=wintun: {} → OK ({} bytes, content-type: {})",
        url,
        bytes.len(),
        content_type
    );
    Some(bytes)
}

/// Пробует все WINTUN_SOURCES по порядку. Первый валидный zip — победа.
fn load_wintun_zip(client: &reqwest::blocking::Client) -> Result<Vec<u8>> {
    for url in WINTUN_SOURCES {
        if let Some(bytes) = try_fetch_wintun_zip(client, url) {
            return Ok(bytes);
        }
    }

    let sources_list: String = WINTUN_SOURCES
        .iter()
        .enumerate()
        .map(|(i, u)| format!("   {}. {}\n", i + 1, u))
        .collect();

    bail!(
        "===============================\n\
         Не удалось скачать wintun.zip\n\
         ===============================\n\
         \n\
         Проверенные источники:\n\
         {sources}\
         \n\
         Ни один из них не отдал валидный zip-архив (сигнатуру PK\\x03\\x04).\n\
         Обычно это значит, что везде отдаётся HTML-страница 404\n\
         с Content-Type: application/zip и размером 8192 байта.\n\
         \n\
         ЧТО СДЕЛАТЬ:\n\
         \n\
         1. Скачай wintun-0.14.1.zip вручную:\n\
         \n\
                https://www.wintun.net/builds/wintun-0.14.1.zip\n\
         \n\
         2. Проверь, что это настоящий zip (первые байты PK):\n\
         \n\
                Format-Hex .\\wintun-0.14.1.zip -Count 4\n\
                # должно быть 50 4B 03 04\n\
         \n\
         3. Скажи мне — я подскажу, как закешировать файл, чтобы\n\
            build.rs его подхватил без сети.\n",
        sources = sources_list,
    )
}

/// Извлекает wintun\bin\amd64\wintun.dll (или любую wintun.dll)
/// из zip-байтов и кладёт в OUT_DIR/wintun.dll.
fn extract_wintun_dll(zip_bytes: Vec<u8>, out: &Path) -> Result<()> {
    let dll_dest = out.join("wintun.dll");
    if dll_dest.exists() {
        println!("cargo:warning=already present: {}", dll_dest.display());
        return Ok(());
    }

    let reader = std::io::Cursor::new(zip_bytes.clone());
    let mut archive = zip::ZipArchive::new(reader)
        .context("open wintun.zip as archive")?;

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
        anyhow!(
            "wintun.dll не найден внутри скачанного архива.\n\
             Искал: amd64/wintun.dll, затем любую wintun.dll.\n\
             \n\
             Содержимое архива (первые 50 записей):\n\
             {}",
            list_zip_entries(&zip_bytes, 50)
        )
    })?;

    let mut entry = archive.by_index(idx)?;
    let name = entry.name().replace('\\', "/");
    let expected_size = entry.size();

    let mut out_file = fs::File::create(&dll_dest)?;
    let copied = std::io::copy(&mut entry, &mut out_file)?;

    println!(
        "cargo:warning=extracted: {} ({} bytes, was {})",
        dll_dest.display(),
        copied,
        expected_size
    );

    if copied < 100_000 {
        bail!(
            "Извлечённый {} весит всего {} байт — это не настоящая wintun.dll.\n\
             Настоящая amd64-DLL весит ~1 MB несжатой.\n\
             Содержимое архива (первые 50 записей):\n\
             {}",
            name,
            copied,
            list_zip_entries(&zip_bytes, 50)
        );
    }

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

    // ── 1. Стандартные ресурсы LaLune ───────────────────────────
    download(&client, URL_LALUNE_ZIP, &out.join("LaLune-Windows.zip"))?;
    download(&client, URL_BACKEND_ZIP, &out.join("Backend-Windows.zip"))?;
    download(&client, URL_CORE_EXE, &out.join("client-windows-x86_64.exe"))?;
    download(&client, URL_LATEST, &out.join("LATEST"))?;
    download(&client, URL_ICON, &out.join("icon.ico"))?;

    // ── 2. wintun.dll — три источника, по порядку ───────────────
    let zip_bytes = load_wintun_zip(&client)?;
    extract_wintun_dll(zip_bytes, &out)?;

    println!(
        "cargo:warning=LaLune installer: all resources ready in {}",
        out.display()
    );
    Ok(())
}
