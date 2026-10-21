// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Мост к крейту csqtt-link (Core/csqtt-link).
// Щедрое логирование, чтобы всё было видно в /logs/tail.

use anyhow::Result;
use csqtt_link::{parse_csqtt_link, CsqttLink as ParsedLink};

pub fn parse(link: &str) -> Result<ParsedLink> {
    let trimmed = link.trim();
    log::info!(
        "[CSQTT-LINK] parse called, input_len={} starts_with_csqtt={}",
        trimmed.len(),
        trimmed.starts_with("csqtt://")
    );

    match parse_csqtt_link(trimmed) {
        Ok(parsed) => {
            log::info!(
                "[CSQTT-LINK] OK: host={} port={} password_len={} hashes={} token_len={}",
                parsed.host,
                parsed.port,
                parsed.password.len(),
                parsed.hashes.len(),
                parsed.vk_access_token.len()
            );
            Ok(parsed)
        }
        Err(e) => {
            log::warn!("[CSQTT-LINK] FAILED: {:#}", e);
            Err(anyhow::anyhow!("csqtt-link: {}", e))
        }
    }
}
