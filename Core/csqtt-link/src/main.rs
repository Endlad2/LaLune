//! `csqtt-link` — CLI для парсинга и дешифровки `csqtt://` ссылок.
//!
//! Читает ссылки из `--url`, позиционных аргументов или stdin.
//! По умолчанию печатает расшифрованную ссылку `csqtt://connect?...`.

use clap::{Parser, ValueEnum};
use csqtt_link::{decrypt_csqtt_payload, parse_csqtt_link, CsqttLink, CsqttLinkError};
use std::io::{self, BufRead, IsTerminal, Read};
use std::process::ExitCode;

#[derive(Parser, Debug)]
#[command(
    name = "csqtt-link",
    version,
    about = "Parse and decrypt csqtt:// links",
    after_help = "EXAMPLES:\n  \
        csqtt-link --url='csqtt://ABC...'\n  \
        csqtt-link 'csqtt://ABC...'\n  \
        echo 'csqtt://ABC...' | csqtt-link\n  \
        csqtt-link --url='csqtt://ABC...' --json"
)]
struct Cli {
    #[arg(short = 'u', long = "url", value_name = "CSQTT_URL",
          action = clap::ArgAction::Append, conflicts_with = "links")]
    urls: Vec<String>,

    #[arg(value_name = "LINK", action = clap::ArgAction::Append,
          conflicts_with = "urls")]
    links: Vec<String>,

    #[arg(short = 'f', long = "format", value_enum, default_value_t = OutputFormat::Url)]
    format: OutputFormat,

    #[arg(long = "json", conflicts_with = "format")]
    json: bool,

    #[arg(long = "stdin")]
    stdin: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum, PartialEq, Eq)]
enum OutputFormat {
    Url,
    Query,
    Fields,
    Json,
    Compact,
}

struct JobResult {
    input: String,
    outcome: Result<CsqttLink, CsqttLinkError>,
}

impl JobResult {
    fn is_ok(&self) -> bool {
        self.outcome.is_ok()
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    if let Err(err) = validate_cli(&cli) {
        eprintln!("error: {err}");
        return ExitCode::from(2);
    }

    let inputs = collect_inputs(&cli);
    if inputs.is_empty() {
        eprintln!(
            "error: no csqtt:// links provided\n\
             hint: pass --url='csqtt://...', a positional LINK, or pipe links on stdin"
        );
        return ExitCode::from(2);
    }

    let format = if cli.json { OutputFormat::Json } else { cli.format };

    let mut results = Vec::with_capacity(inputs.len());
    for raw in inputs.into_iter() {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        let (outcome, plaintext) = decrypt_once(trimmed);
        let result = JobResult {
            input: trimmed.to_string(),
            outcome,
        };
        print_result(&result, format, plaintext.as_deref());
        results.push(result);
    }

    if results.iter().all(JobResult::is_ok) {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn decrypt_once(link: &str) -> (Result<CsqttLink, CsqttLinkError>, Option<String>) {
    let payload = match link.strip_prefix("csqtt://") {
        Some(rest) => rest.trim(),
        None => return (Err(CsqttLinkError::InvalidScheme), None),
    };
    let plaintext = match decrypt_csqtt_payload(payload) {
        Ok(text) => text,
        Err(err) => return (Err(err), None),
    };
    let parsed = parse_csqtt_link(link);
    (parsed, Some(plaintext))
}

fn validate_cli(cli: &Cli) -> Result<(), String> {
    if !cli.urls.is_empty() && !cli.links.is_empty() {
        return Err("cannot mix --url with positional links".into());
    }
    Ok(())
}

fn collect_inputs(cli: &Cli) -> Vec<String> {
    if !cli.urls.is_empty() {
        return cli.urls.clone();
    }
    if !cli.links.is_empty() {
        return cli.links.clone();
    }
    let stdin_is_tty = io::stdin().is_terminal();
    let should_read_stdin = cli.stdin || !stdin_is_tty;
    if !should_read_stdin {
        return Vec::new();
    }
    let stdin = io::stdin();
    if cli.stdin {
        let mut buf = String::new();
        if stdin.lock().read_to_string(&mut buf).is_err() {
            return Vec::new();
        }
        buf.lines().map(str::to_string).collect()
    } else {
        stdin.lock().lines().map_while(Result::ok).collect()
    }
}

fn print_result(result: &JobResult, format: OutputFormat, plaintext: Option<&str>) {
    match (&result.outcome, format) {
        (Ok(info), OutputFormat::Url) => println!("csqtt://{}", as_query(info, plaintext)),
        (Ok(info), OutputFormat::Query) => println!("{}", as_query(info, plaintext)),
        (Ok(info), OutputFormat::Fields) => print_fields(&result.input, info),
        (Ok(info), OutputFormat::Json) => print_json_ok(&result.input, info, plaintext),
        (Ok(info), OutputFormat::Compact) => println!(
            "OK  {}  {}  password={}  hashes={}  token={}",
            result.input,
            info.peer_address(),
            if info.password.is_empty() { "no" } else { "yes" },
            info.hashes.len(),
            if info.vk_access_token.is_empty() { "no" } else { "yes" },
        ),
        (Err(err), OutputFormat::Json) => print_json_err(&result.input, err),
        (Err(err), _) => eprintln!("error: {}: {err}", result.input),
    }
}

fn as_query(info: &CsqttLink, plaintext: Option<&str>) -> String {
    if let Some(text) = plaintext {
        let text = text.trim();
        if let Some(rest) = text.strip_prefix("csqtt://connect?") {
            return format!("connect?{}", rest);
        }
        if let Some(rest) = text.strip_prefix("connect?") {
            return format!("connect?{}", rest);
        }
        if let Some(rest) = text.strip_prefix("csqtt://") {
            return format!("connect?{}", rest);
        }
        if text.starts_with("host=") || text.contains("&host=") {
            return format!("connect?{}", text);
        }
    }
    let full = info.to_link();
    full.trim_start_matches("csqtt://").to_string()
}

fn print_fields(input: &str, info: &CsqttLink) {
    println!("Link:     {input}");
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
    println!();
}

fn print_json_ok(input: &str, info: &CsqttLink, plaintext: Option<&str>) {
    let json = serde_json::json!({
        "ok": true,
        "input": input,
        "url": format!("csqtt://{}", as_query(info, plaintext)),
        "query": as_query(info, plaintext),
        "plaintext": plaintext,
        "host": info.host,
        "port": info.port,
        "peer": info.peer_address(),
        "password": info.password,
        "hashes": info.hashes,
        "vk_access_token": info.vk_access_token,
    });
    println!("{json}");
}

fn print_json_err(input: &str, err: &CsqttLinkError) {
    let json = serde_json::json!({
        "ok": false,
        "input": input,
        "error": err.to_string(),
    });
    println!("{json}");
}
