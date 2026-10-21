//! Round-trip example: encrypt a plaintext config, then decrypt it back.
//!
//! Usage:
//!   cargo run --example roundtrip

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use sha2::{Digest, Sha256};

const CIPHER_SEED: &str = "csqtt-chiper-key";

fn encrypt(plaintext: &str) -> String {
    let key: [u8; 32] = Sha256::digest(CIPHER_SEED.as_bytes()).into();
    let cipher = Aes256Gcm::new_from_slice(&key).unwrap();

    // Deterministic IV: sha256(plaintext)[:12] — как в CSQTT клиенте.
    let digest = Sha256::digest(plaintext.as_bytes());
    let mut iv = [0u8; 12];
    iv.copy_from_slice(&digest[..12]);

    let nonce = Nonce::from_slice(&iv);
    let ct = cipher.encrypt(nonce, plaintext.as_bytes()).unwrap();

    let mut combined = Vec::with_capacity(12 + ct.len());
    combined.extend_from_slice(&iv);
    combined.extend_from_slice(&ct);
    URL_SAFE_NO_PAD.encode(&combined)
}

fn main() {
    let plaintext =
        "connect?v=2&host=203.0.113.7&peer=46000&password=secret&hashes=abcdefghijklmnop1";
    let encoded = encrypt(plaintext);
    println!("Encrypted payload: {}", encoded);
    println!("Full link:         csqtt://{}", encoded);

    use csqtt_link::parse_csqtt_link;
    let info = parse_csqtt_link(&format!("csqtt://{}", encoded)).expect("roundtrip");
    assert_eq!(info.host, "203.0.113.7");
    assert_eq!(info.port, 46000);
    assert_eq!(info.password, "secret");
    assert_eq!(info.hashes, vec!["abcdefghijklmnop1"]);
    println!("Round-trip verified ✓");
}
