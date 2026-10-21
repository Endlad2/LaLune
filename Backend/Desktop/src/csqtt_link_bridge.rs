// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Мост к крейту csqtt-link (Core/csqtt-link).
//
// csqtt-link — основной парсер csqtt:// ссылок (AES-256-GCM).
// Если он вернул ошибку — вызывающий код падает на Lua / нативный парсер.

use anyhow::Result;
use csqtt_link::{parse_csqtt_link, CsqttLink as ParsedLink};

/// Парсит csqtt:// ссылку через крейт csqtt-link.
pub fn parse(link: &str) -> Result<ParsedLink> {
    parse_csqtt_link(link).map_err(|e| anyhow::anyhow!("csqtt-link: {}", e))
}
