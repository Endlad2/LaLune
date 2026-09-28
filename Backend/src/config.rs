//! Конфиги: SQLite ~/.la-lune/configs.db.
//!
//! Схема повторяет Go-версию:
//!   id, protocol, peer, password, hashes, name, rawLink (в памяти).

use std::path::Path;
use anyhow::Result;
use rusqlite::Connection;
use url::Url;

use crate::state::Config;

pub fn open_db(path: &Path) -> Result<()> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        r#"CREATE TABLE IF NOT EXISTS configs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            protocol TEXT NOT NULL DEFAULT 'CSQTT',
            peer TEXT NOT NULL DEFAULT '',
            password TEXT NOT NULL DEFAULT '',
            hashes TEXT NOT NULL DEFAULT '',
            name TEXT DEFAULT '',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );"#,
    )?;
    Ok(())
}

pub fn load_configs() -> Result<Vec<Config>> {
    let conn = Connection::open(crate::configs_db_path())?;
    let mut stmt = conn.prepare(
        "SELECT id, protocol, peer, password, hashes, name FROM configs ORDER BY id DESC",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(Config {
            id: r.get(0)?,
            protocol: r.get(1)?,
            peer: r.get(2)?,
            password: r.get(3)?,
            hashes: r.get(4)?,
            name: r.get(5)?,
            raw_link: String::new(),
        })
    })?;
    let mut out = Vec::new();
    for row in rows { out.push(row?); }
    Ok(out)
}

pub fn insert_config(c: &Config) -> Result<i64> {
    let conn = Connection::open(crate::configs_db_path())?;
    conn.execute(
        "INSERT INTO configs (protocol, peer, password, hashes, name) VALUES (?, ?, ?, ?, ?)",
        (&c.protocol, &c.peer, &c.password, &c.hashes, &c.name),
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn delete_config(id: i64) -> Result<()> {
    let conn = Connection::open(crate::configs_db_path())?;
    conn.execute("DELETE FROM configs WHERE id = ?", [id])?;
    Ok(())
}

pub fn get_config(id: i64) -> Result<Option<Config>> {
    let conn = Connection::open(crate::configs_db_path())?;
    let mut stmt = conn.prepare(
        "SELECT id, protocol, peer, password, hashes, name FROM configs WHERE id = ?",
    )?;
    let mut rows = stmt.query([id])?;
    if let Some(r) = rows.next()? {
        Ok(Some(Config {
            id: r.get(0)?,
            protocol: r.get(1)?,
            peer: r.get(2)?,
            password: r.get(3)?,
            hashes: r.get(4)?,
            name: r.get(5)?,
            raw_link: String::new(),
        }))
    } else {
        Ok(None)
    }
}

/// Разбор ссылок вида:
///   csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2
///   csqtt://password@host:port
pub fn parse_link(link: &str, protocol: &str) -> Config {
    let protocol = normalize_protocol(protocol);
    let trimmed = link.trim();
    let mut cfg = Config {
        id: 0,
        protocol: protocol.clone(),
        peer: trimmed.to_string(),
        password: String::new(),
        hashes: String::new(),
        name: trimmed.to_string(),
        raw_link: trimmed.to_string(),
    };

    if !trimmed.to_lowercase().starts_with("csqtt://") {
        return cfg;
    }

    let parsed = match Url::parse(trimmed) {
        Ok(u) => u,
        Err(_) => return cfg,
    };

    if parsed.host_str() == Some("connect") {
        let pairs = parsed.query_pairs();
        let mut host = String::new();
        let mut port = String::new();
        let mut password = String::new();
        let mut hashes: Vec<String> = Vec::new();
        for (k, v) in pairs {
            match k.as_ref() {
                "host" => host = v.into_owned(),
                "peer" => port = v.into_owned(),
                "password" => password = v.into_owned(),
                "hashes" => {
                    hashes = v
                        .split('+')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                }
                _ => {}
            }
        }
        if !host.is_empty() && !port.is_empty() {
            cfg.peer = format!("{host}:{port}");
            cfg.password = password;
            cfg.hashes = hashes.join(",");
            cfg.name = cfg.peer.clone();
        }
    } else {
        let host = parsed.host_str().unwrap_or("").to_string();
        let port = parsed.port().unwrap_or(46000);
        let password = parsed.username().to_string();
        if !host.is_empty() {
            cfg.peer = format!("{host}:{port}");
            cfg.password = password;
            cfg.name = cfg.peer.clone();
        }
    }
    cfg
}

pub fn normalize_protocol(p: &str) -> String {
    match p.trim().to_lowercase().as_str() {
        "" | "csqtt" => "CSQTT".into(),
        "freeturn" | "free-turn" | "ftp" => "FREETURN".into(),
        "olcrtc" | "olc" => "OLCRTC".into(),
        "openflux" => "OPENFLUX".into(),
        "tots" => "TOTS".into(),
        other => other.to_uppercase(),
    }
}
