use csqtt_link::{decrypt_csqtt_payload, parse_csqtt_link, parse_plaintext, strip_vk_url};

const SAMPLE_ENCRYPTED: &str =
    "GNANVH0fhD6MisDFiWP_P0Bm_FHr-frawgfwur3Zx4ipjJx8gk-M6ZZbnDr_2clwPmzO-QS8AkiHLaMXyYO1RHyPeehXPqTc6jJi_iw72fRQJ9AR918ne5XsBRg";

#[test]
fn decrypt_known_payload() {
    let plaintext = decrypt_csqtt_payload(SAMPLE_ENCRYPTED).expect("decrypt");
    assert!(plaintext.starts_with("connect?"), "plaintext: {plaintext}");
    assert!(plaintext.contains("host=1.2.3.4"), "plaintext: {plaintext}");
    assert!(plaintext.contains("peer=46000"), "plaintext: {plaintext}");
}

#[test]
fn parse_known_link() {
    let link = format!("csqtt://{}", SAMPLE_ENCRYPTED);
    let info = parse_csqtt_link(&link).expect("parse");
    assert_eq!(info.host, "1.2.3.4");
    assert_eq!(info.port, 46000);
    assert_eq!(info.peer_address(), "1.2.3.4:46000");
}

#[test]
fn reject_bad_scheme() {
    let err = parse_csqtt_link("https://example.com/").unwrap_err();
    assert!(matches!(err, csqtt_link::CsqttLinkError::InvalidScheme));
}

#[test]
fn reject_tampered_payload() {
    // Flip the last base64 char to something that is still valid base64 but
    // changes the trailing GCM tag bytes.
    let mut payload = SAMPLE_ENCRYPTED.to_string();
    let last = payload.pop().unwrap();
    payload.push(if last == 'A' { 'B' } else { 'A' });
    let err = parse_csqtt_link(&format!("csqtt://{}", payload)).unwrap_err();
    assert!(
        matches!(err, csqtt_link::CsqttLinkError::DecryptionFailed)
            || matches!(err, csqtt_link::CsqttLinkError::InvalidFormat(_))
            || matches!(err, csqtt_link::CsqttLinkError::InvalidBase64(_)),
        "unexpected error: {err:?}"
    );
}

#[test]
fn parse_plaintext_with_hashes() {
    let plain =
        "connect?v=2&host=203.0.113.7&peer=46000&password=p%40ss&hashes=abcdefghijklmnop1%2Bx";
    let info = parse_plaintext(plain).expect("parse");
    assert_eq!(info.host, "203.0.113.7");
    assert_eq!(info.port, 46000);
    assert_eq!(info.password, "p@ss");
    assert_eq!(info.hashes, vec!["abcdefghijklmnop1+x"]);
}

#[test]
fn parse_plaintext_with_token() {
    let plain = "connect?v=2&host=vps.example&peer=46000&password=secret&token=vk1.aBc-_%2B9";
    let info = parse_plaintext(plain).expect("parse");
    assert_eq!(info.vk_access_token, "vk1.aBc-_+9");
    assert!(info.hashes.is_empty());
}

#[test]
fn parse_plaintext_concatenated() {
    let plain = "connect?v=2host=203.0.113.88peer=46000password=dummy_secret_pass";
    let info = parse_plaintext(plain).expect("parse");
    assert_eq!(info.host, "203.0.113.88");
    assert_eq!(info.port, 46000);
    assert_eq!(info.password, "dummy_secret_pass");
}

#[test]
fn reject_unsupported_version() {
    let plain = "connect?v=3&host=1.2.3.4&peer=46000";
    assert!(parse_plaintext(plain).is_err());
}

#[test]
fn reject_invalid_port() {
    let plain = "connect?v=2&host=1.2.3.4&peer=0&password=secret";
    assert!(parse_plaintext(plain).is_err());
}

#[test]
fn reject_short_hash() {
    // `hashes` is present -> must fail, not silently drop.
    let plain = "connect?v=2&host=1.2.3.4&peer=46000&password=secret&hashes=short";
    let err = parse_plaintext(plain).unwrap_err();
    assert!(
        matches!(err, csqtt_link::CsqttLinkError::InvalidParameter { .. }),
        "unexpected error: {err:?}"
    );
}

#[test]
fn reject_both_hashes_and_token() {
    let plain =
        "connect?v=2&host=1.2.3.4&peer=46000&password=secret&hashes=abcdefghijklmnop&token=token";
    assert!(parse_plaintext(plain).is_err());
}

#[test]
fn strip_vk_url_handles_prefixes() {
    assert_eq!(
        strip_vk_url("https://vk.com/call/join/abcdefghijklmnop"),
        "abcdefghijklmnop"
    );
    assert_eq!(
        strip_vk_url("vk.ru/call/join/abcdefghijklmnop?x=1"),
        "abcdefghijklmnop"
    );
    assert_eq!(strip_vk_url("plain-hash-16chars"), "plain-hash-16chars");
}

#[test]
fn peer_address_formats_ipv6() {
    let plain = "connect?v=2&host=2001%3Adb8%3A%3A1&peer=46000&password=secret";
    let info = parse_plaintext(plain).expect("parse");
    assert_eq!(info.peer_address(), "[2001:db8::1]:46000");
}

#[test]
fn reject_localhost() {
    let plain = "connect?v=2&host=127.0.0.1&peer=46000";
    assert!(parse_plaintext(plain).is_err());
}
