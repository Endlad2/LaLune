//! Simple example: decrypt a CSQTT link passed as a command-line argument.
//!
//! Usage:
//!   cargo run --example decrypt -- "csqtt://<payload>"

use csqtt_link::{parse_csqtt_link, CsqttLinkError};

fn main() -> Result<(), CsqttLinkError> {
    let arg = std::env::args()
        .nth(1)
        .ok_or_else(|| CsqttLinkError::InvalidFormat("usage: decrypt <csqtt://...>".into()))?;

    let link = if arg.starts_with("csqtt://") {
        arg
    } else {
        format!("csqtt://{}", arg)
    };

    let info = parse_csqtt_link(&link)?;

    println!("Host:     {}", info.host);
    println!("Port:     {}", info.port);
    println!("Peer:     {}", info.peer_address());
    println!(
        "Password: {}",
        if info.password.is_empty() { "(none)" } else { &info.password }
    );
    if !info.hashes.is_empty() {
        println!("Hashes:   {}", info.hashes.join(", "));
    }
    if !info.vk_access_token.is_empty() {
        println!("VK token: {}", info.vk_access_token);
    }

    Ok(())
}
