// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Конфиги: SQLite-хранилище + парсинг csqtt:// ссылок.

use anyhow::{anyhow, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Arc;
use parking_lot::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigItem {
    pub id: i64,
    pub protocol: String,
    pub peer: String,
    pub password: String,
    pub hashes: String,
    pub name: String,
    #[serde(default)]
    pub raw_link: String,
}

#[derive(Debug, Clone)]
pub struct ConfigStore {
    conn: Arc<Mutex<Connection>>,
}

impl ConfigStore {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS configs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                protocol TEXT NOT NULL DEFAULT 'CSQTT',
                peer TEXT NOT NULL DEFAULT '',
                password TEXT NOT NULL DEFAULT '',
                hashes TEXT NOT NULL DEFAULT '',
                name TEXT DEFAULT '',
                raw_link TEXT DEFAULT '',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            "#,
        )?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    pub fn list(&self) -> Result<Vec<ConfigItem>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, protocol, peer, password, hashes, name, raw_link \
             FROM configs ORDER BY id DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(ConfigItem {
                id: r.get(0)?,
                protocol: r.get(1)?,
                peer: r.get(2)?,
                password: r.get(3)?,
                hashes: r.get(4)?,
                name: r.get(5)?,
                raw_link: r.get(6).unwrap_or_default(),
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn get(&self, id: i64) -> Result<Option<ConfigItem>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, protocol, peer, password, hashes, name, raw_link \
             FROM configs WHERE id = ?",
        )?;
        let mut rows = stmt.query(params![id])?;
        if let Some(r) = rows.next()? {
            Ok(Some(ConfigItem {
                id: r.get(0)?,
                protocol: r.get(1)?,
                peer: r.get(2)?,
                password: r.get(3)?,
                hashes: r.get(4)?,
                name: r.get(5)?,
                raw_link: r.get(6).unwrap_or_default(),
            }))
        } else {
            Ok(None)
        }
    }

    pub fn insert(&self, c: &ConfigItem) -> Result<i64> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO configs (protocol, peer, password, hashes, name, raw_link) \
             VALUES (?, ?, ?, ?, ?, ?)",
            params![
                c.protocol,
                c.peer,
                c.password,
                c.hashes,
                c.name,
                c.raw_link
            ],
        )?;
        Ok(conn.last_insert_rowid())
    }

    pub fn update(&self, id: i64, c: &ConfigItem) -> Result<()> {
        let conn = self.conn.lock();
        let n = conn.execute(
            "UPDATE configs SET protocol=?, peer=?, password=?, hashes=?, name=?, \
             raw_link=?, updated_at=CURRENT_TIMESTAMP WHERE id=?",
            params![
                c.protocol,
                c.peer,
                c.password,
                c.hashes,
                c.name,
                c.raw_link,
                id
            ],
        )?;
        if n == 0 {
            return Err(anyhow!("config {} not found", id));
        }
        Ok(())
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute("DELETE FROM configs WHERE id = ?", params![id])?;
        Ok(())
    }
}

/// Парсит csqtt://... и другие схемы. Возвращает ConfigItem без id.
pub fn parse_link(link: &str) -> Result<ConfigItem> {
    let link = link.trim();
    let lower = link.to_ascii_lowercase();

    if lower.starts_with("csqtt://") {
        parse_csqtt(link)
    } else if lower.starts_with("olcrtc://") {
        parse_generic(link, "OLCRTC", "olcrtc://")
    } else if lower.starts_with("tots://") {
        parse_generic(link, "TOTS", "tots://")
    } else if lower.starts_with("openflux://") {
        parse_generic(link, "OPENFLUX", "openflux://")
    } else {
        Err(anyhow!("unsupported scheme"))
    }
}

fn parse_csqtt(link: &str) -> Result<ConfigItem> {
    // csqtt://connect?v=2&host=H&peer=P&password=PWD&hashes=h1+h2+h3
    // или csqtt://password@host:port
    let rest = link.trim_start_matches("csqtt://");

    if let Some(query) = rest.strip_prefix("connect?") {
        let mut host = String::new();
        let mut port = String::new();
        let mut password = String::new();
        let mut hashes_raw = String::new();

        for kv in query.split('&') {
            let mut parts = kv.splitn(2, '=');
            let k = parts.next().unwrap_or("");
            let v = parts.next().unwrap_or("");
            match k {
                "host" => host = v.to_string(),
                "peer" => port = v.to_string(),
                "password" => password = v.to_string(),
                "hashes" => hashes_raw = v.to_string(),
                _ => {}
            }
        }

        if host.is_empty() || port.is_empty() || password.is_empty() {
            return Err(anyhow!("csqtt:// missing host/peer/password"));
        }

        let hashes: Vec<String> = hashes_raw
            .split('+')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();

        let peer = format!("{}:{}", host, port);
        return Ok(ConfigItem {
            id: 0,
            protocol: "CSQTT".into(),
            peer: peer.clone(),
            password,
            hashes: hashes.join(","),
            name: peer.clone(),
            raw_link: link.to_string(),
        });
    }

    // csqtt://password@host:port
    if let Some(at) = rest.find('@') {
        let (userinfo, hostport) = rest.split_at(at);
        let hostport = &hostport[1..];
        let password = userinfo
            .splitn(2, ':')
            .nth(1)
            .unwrap_or("")
            .to_string();
        let peer = if hostport.contains(':') {
            hostport.to_string()
        } else {
            format!("{}:46000", hostport)
        };
        return Ok(ConfigItem {
            id: 0,
            protocol: "CSQTT".into(),
            peer: peer.clone(),
            password,
            hashes: String::new(),
            name: peer,
            raw_link: link.to_string(),
        });
    }

    Err(anyhow!("csqtt:// invalid format"))
}

fn parse_generic(link: &str, protocol: &str, prefix: &str) -> Result<ConfigItem> {
    let rest = link.trim_start_matches(prefix);
    // peer=H:P;password=PWD;hashes=h1,h2,h3;name=NAME
    let mut peer = String::new();
    let mut password = String::new();
    let mut hashes = String::new();
    let mut name = String::new();

    for kv in rest.split(';') {
        let mut parts = kv.splitn(2, '=');
        let k = parts.next().unwrap_or("");
        let v = parts.next().unwrap_or("");
        match k {
            "peer" | "host" => peer = v.to_string(),
            "password" => password = v.to_string(),
            "hashes" => hashes = v.replace('+', ","),
            "name" => name = v.to_string(),
            _ => {}
        }
    }

    if peer.is_empty() {
        return Err(anyhow!("{} missing peer", protocol));
    }
    if name.is_empty() {
        name = peer.clone();
    }

    Ok(ConfigItem {
        id: 0,
        protocol: protocol.into(),
        peer,
        password,
        hashes,
        name,
        raw_link: link.to_string(),
    })
}
