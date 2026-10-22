use clap::Parser;
use csqtt_link::{parse_csqtt_link, parse_freeturn_link};
use std::io::{self, Read};
use std::process::ExitCode;

#[derive(Parser, Debug)]
#[command(name = "csqtt-link")]
struct Cli {
    #[arg(short = 'u', long = "url")]
    url: Option<String>,
    #[arg(long = "json")]
    json: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let input = if let Some(u) = cli.url {
        u
    } else {
        let mut buf = String::new();
        io::stdin().read_to_string(&mut buf).unwrap();
        buf.trim().to_string()
    };

    if input.is_empty() { return ExitCode::FAILURE; }

    if input.starts_with("freeturn://") {
        match parse_freeturn_link(&input) {
            Ok(link) => {
                println!("{}", serde_json::to_string_pretty(&link).unwrap());
                ExitCode::SUCCESS
            }
            Err(e) => { eprintln!("{}", e); ExitCode::FAILURE }
        }
    } else {
        match parse_csqtt_link(&input) {
            Ok(link) => {
                println!("{}", serde_json::to_string_pretty(&link).unwrap());
                ExitCode::SUCCESS
            }
            Err(e) => { eprintln!("{}", e); ExitCode::FAILURE }
        }
    }
}
