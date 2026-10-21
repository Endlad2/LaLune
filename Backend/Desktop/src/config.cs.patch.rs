// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// ПАТЧ для Backend/Desktop/src/config.rs.
//
// Заменить функцию `parse_csqtt` на эту реализацию — она использует
// крейт csqtt-link (Core/csqtt-link), а при ошибке падает на нативный
// парсер (plain v=2 и user:pass@host).

use crate::csqtt_link_bridge;

pub fn parse_csqtt(link: &str) -> Result<ConfigItem> {
    // 1. csqtt-link (AES-256-GCM, рекомендованный парсер).
    if let Ok(parsed) = csqtt_link_bridge::parse(link) {
        let mut cfg = ConfigItem::default();
        cfg.protocol = "CSQTT".into();
        cfg.peer = parsed.peer_address();
        cfg.password = parsed.password.clone();
        cfg.hashes = parsed.hashes.join(",");
        cfg.name = parsed.peer_address();
        cfg.raw_link = link.to_string();
        return Ok(cfg);
    }

    // 2. Lua fallback (если пользователь положил csqtt_decode.lua).
    if let Some(lua) = crate::lua_runtime::global_runtime() {
        if let Ok(decoded) = lua.decode_csqtt_link(link) {
            let mut cfg = ConfigItem::default();
            cfg.protocol = "CSQTT".into();
            cfg.peer = decoded.peer.clone();
            cfg.password = decoded.password.clone();
            cfg.hashes = decoded.hashes.clone();
            cfg.name = if decoded.name.is_empty() {
                decoded.peer.clone()
            } else {
                decoded.name.clone()
            };
            cfg.raw_link = link.to_string();
            return Ok(cfg);
        }
    }

    // 3. Нативный fallback (plain v=2 / user:pass@host).
    parse_csqtt_native(link)
}
