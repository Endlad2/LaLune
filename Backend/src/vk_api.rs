//! VK API: calls.start / calls.forceFinish.

use std::collections::VecDeque;
use std::time::Duration;
use anyhow::{anyhow, Result};
use serde_json::Value;

const VK_API: &str = "https://api.vk.ru/method/";
const VK_VER: &str = "5.199";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
    AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MAX_CALLS: usize = 6;

fn call(method: &str, token: &str, params: &[(&str, &str)]) -> Result<Value> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()?;
    let mut form: Vec<(&str, &str)> = params.to_vec();
    form.push(("v", VK_VER));
    let resp = client
        .post(format!("{VK_API}{method}"))
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("User-Agent", UA)
        .header("Origin", "https://vk.com")
        .header("Referer", "https://vk.com/")
        .form(&form)
        .send()?;
    let v: Value = resp.json()?;
    Ok(v)
}

pub fn create_calls(
    token: &str,
    workers: i64,
    auto_api_workers: i64,
    logs: &mut VecDeque<String>,
) -> Result<(Vec<String>, Vec<String>)> {
    let aw = if auto_api_workers < 1 { 9 } else { auto_api_workers };
    let w = if workers < 1 { 9 } else { workers };
    let count = ((w + aw - 1) / aw) as usize;
    let count = count.clamp(1, MAX_CALLS);

    let mut hashes = Vec::new();
    let mut ids = Vec::new();

    for i in 0..count {
        if i > 0 {
            std::thread::sleep(Duration::from_millis(80));
        }
        let v = call("calls.start", token, &[])?;
        if let Some(err) = v.get("error") {
            let code = err.get("error_code").and_then(|c| c.as_i64()).unwrap_or(0);
            let msg = err.get("error_msg").and_then(|c| c.as_str()).unwrap_or("");
            logs.push_back(format!("[VK] calls.start error {code}: {msg}"));
            if matches!(code, 4 | 5 | 27 | 28) {
                return Err(anyhow!("токен недействителен"));
            }
            continue;
        }
        let resp = v.get("response").ok_or_else(|| anyhow!("нет response"))?;
        let call_id = resp.get("call_id").and_then(|c| c.as_str()).unwrap_or("").to_string();
        let join_link = resp.get("join_link").and_then(|c| c.as_str()).unwrap_or("").to_string();
        let ok_join = resp.get("ok_join_link").and_then(|c| c.as_str()).unwrap_or("").to_string();
        let hash = if !ok_join.is_empty() {
            ok_join
        } else if !join_link.is_empty() {
            join_link.rsplit('/').next().unwrap_or("").to_string()
        } else {
            String::new()
        };
        if !call_id.is_empty() && !hash.is_empty() {
            hashes.push(hash);
            ids.push(call_id);
        }
    }

    logs.push_back(format!("[VK] создано звонков: {}/{}", ids.len(), count));
    Ok((hashes, ids))
}

#[allow(dead_code)]
pub fn finish_all(token: &str, call_ids: &[String], logs: &mut VecDeque<String>) {
    for id in call_ids {
        if let Err(e) = call("calls.forceFinish", token, &[("call_id", id)]) {
            logs.push_back(format!("[VK] forceFinish error: {e}"));
        }
    }
}
