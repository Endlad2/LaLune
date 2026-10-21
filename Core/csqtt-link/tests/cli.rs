//! End-to-end CLI tests, exercised through the compiled `csqtt-link` binary.

use assert_cmd::Command;
use predicates::prelude::*;

const SAMPLE_ENCRYPTED: &str =
    "GNANVH0fhD6MisDFiWP_P0Bm_FHr-frawgfwur3Zx4ipjJx8gk-M6ZZbnDr_2clwPmzO-QS8AkiHLaMXyYO1RHyPeehXPqTc6jJi_iw72fRQJ9AR918ne5XsBRg";

fn sample_link() -> String {
    format!("csqtt://{SAMPLE_ENCRYPTED}")
}

fn cmd() -> Command {
    Command::cargo_bin("csqtt-link").expect("binary is built")
}

#[test]
fn url_flag_decrypts_known_link() {
    cmd()
        .arg("--url")
        .arg(sample_link())
        .assert()
        .success()
        .stdout(predicate::str::contains("Host:     1.2.3.4"))
        .stdout(predicate::str::contains("Port:     46000"))
        .stdout(predicate::str::contains("Peer:     1.2.3.4:46000"));
}

#[test]
fn url_flag_equals_form_is_accepted() {
    cmd()
        .arg(format!("--url={}", sample_link()))
        .assert()
        .success()
        .stdout(predicate::str::contains("Host:     1.2.3.4"));
}

#[test]
fn short_url_flag_is_accepted() {
    cmd()
        .arg("-u")
        .arg(sample_link())
        .assert()
        .success()
        .stdout(predicate::str::contains("Host:     1.2.3.4"));
}

#[test]
fn positional_link_is_accepted() {
    cmd()
        .arg(sample_link())
        .assert()
        .success()
        .stdout(predicate::str::contains("Host:     1.2.3.4"));
}

#[test]
fn default_output_is_full_csqtt_url() {
    // The default format now emits a full csqtt://connect?... URL.
    cmd()
        .arg("--url")
        .arg(sample_link())
        .assert()
        .success()
        .stdout(predicate::str::starts_with("csqtt://connect?v=2"))
        .stdout(predicate::str::contains("host=1.2.3.4"))
        .stdout(predicate::str::contains("peer=46000"));
}

#[test]
fn query_format_omits_scheme() {
    cmd()
        .arg("--url")
        .arg(sample_link())
        .arg("--format")
        .arg("query")
        .assert()
        .success()
        .stdout(predicate::str::starts_with("connect?v=2"))
        .stdout(predicate::str::contains("host=1.2.3.4"))
        .stdout(predicate::str::contains("peer=46000"));
}

#[test]
fn url_format_matches_explicit_flag() {
    let default_out = cmd()
        .arg("--url")
        .arg(sample_link())
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let explicit_out = cmd()
        .arg("--url")
        .arg(sample_link())
        .arg("--format")
        .arg("url")
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    assert_eq!(default_out, explicit_out);
}

#[test]
fn fields_format_is_human_readable() {
    cmd()
        .arg("--url")
        .arg(sample_link())
        .arg("--format")
        .arg("fields")
        .assert()
        .success()
        .stdout(predicate::str::contains("Link:     csqtt://"))
        .stdout(predicate::str::contains("Peer:     1.2.3.4:46000"));
}

#[test]
fn json_output_is_machine_readable() {
    let out = cmd()
        .arg("--url")
        .arg(sample_link())
        .arg("--json")
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let text = String::from_utf8(out).expect("stdout is utf8");
    let parsed: serde_json::Value = serde_json::from_str(text.trim()).expect("valid json");
    assert_eq!(parsed["ok"], true);
    assert_eq!(parsed["host"], "1.2.3.4");
    assert_eq!(parsed["port"], 46000);
    assert_eq!(parsed["peer"], "1.2.3.4:46000");

    let url = parsed["url"].as_str().expect("url field is present");
    assert!(url.starts_with("csqtt://connect?v=2"));
    assert!(url.contains("host=1.2.3.4"));
    assert!(url.contains("peer=46000"));

    let query = parsed["query"].as_str().expect("query field is present");
    assert!(query.starts_with("connect?v=2"));
}

#[test]
fn multiple_urls_each_produce_a_block() {
    let out = cmd()
        .arg("--url")
        .arg(sample_link())
        .arg("--url")
        .arg(sample_link())
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let text = String::from_utf8(out).expect("stdout is utf8");
    let count = text.matches("host=1.2.3.4").count();
    assert_eq!(count, 2, "expected two decrypted blocks, got: {text}");
}

#[test]
fn invalid_link_exits_with_failure() {
    cmd()
        .arg("--url")
        .arg("csqtt://AAAA")
        .assert()
        .failure()
        .stderr(predicate::str::contains("error:"));
}

#[test]
fn bad_scheme_exits_with_failure() {
    cmd()
        .arg("--url")
        .arg("https://example.com/")
        .assert()
        .failure()
        .stderr(predicate::str::contains("does not start with csqtt://"));
}

#[test]
fn no_inputs_shows_usage_hint() {
    cmd()
        .assert()
        .failure()
        .code(2)
        .stderr(predicate::str::contains("no csqtt:// links provided"));
}

#[test]
fn stdin_is_used_when_no_args_are_given() {
    let link = sample_link();
    cmd()
        .write_stdin(format!("{link}\n"))
        .assert()
        .success()
        .stdout(predicate::str::contains("host=1.2.3.4"));
}

#[test]
fn compact_output_has_peer_and_flags() {
    cmd()
        .arg("--url")
        .arg(sample_link())
        .arg("--format")
        .arg("compact")
        .assert()
        .success()
        .stdout(predicate::str::contains("OK"))
        .stdout(predicate::str::contains("1.2.3.4:46000"));
}

#[test]
fn url_and_positional_cannot_be_mixed() {
    cmd()
        .arg("--url")
        .arg(sample_link())
        .arg(sample_link())
        .assert()
        .failure()
        .code(2);
}
