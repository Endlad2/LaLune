// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// OpenWRT: csqtt-link как библиотека.

use anyhow::Result;
use csqtt_link::{parse_csqtt_link, CsqttLink as ParsedLink};

pub fn parse(link: &str) -> Result<ParsedLink> {
    parse_csqtt_link(link).map_err(|e| anyhow::anyhow!("csqtt-link: {}", e))
}
