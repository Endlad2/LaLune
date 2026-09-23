// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// deploy-manager - cross-platform deployer for LaLune protocol cores.
//
// This binary is built on every platform (including Android, where it is
// shipped as a *binary* inside the app's native libs and executed via
// Process.exec), copied into the app bundle, and invoked by the "Deploy" tab.
//
// It connects to a user-provided server over SSH and installs the selected
// protocol core (CSQTT / FreeTurn / OlcRTC / OpenFlux / ToTS).
//
// SSH is performed by shelling out to the operating system's OpenSSH client
// (`ssh`), which is available on Windows 10+, Linux and macOS. This keeps the
// crate free of native/C dependencies so it cross-compiles to all targets.

mod deploy;
mod protocol;

use clap::{Parser, Subcommand};
use std::process::ExitCode;

#[derive(Parser, Debug)]
#[command(
    name = "deploy-manager",
    about = "Deploy a LaLune protocol core to a remote server over SSH",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Deploy a protocol core to a server over SSH.
    Deploy(DeployArgs),
    /// List the protocols this build can deploy.
    Protocols,
}

#[derive(Parser, Debug)]
pub struct DeployArgs {
    /// Protocol to deploy: csqtt | freeturn | olcrtc | openflux | tots.
    #[arg(long)]
    pub protocol: String,

    /// Server address (IP or hostname).
    #[arg(long)]
    pub host: String,

    /// SSH port.
    #[arg(long, default_value_t = 22)]
    pub ssh_port: u16,

    /// SSH user.
    #[arg(long, default_value = "root")]
    pub user: String,

    /// SSH password (mutually exclusive with --key).
    #[arg(long, conflicts_with = "key")]
    pub password: Option<String>,

    /// Path to a private SSH key (mutually exclusive with --password).
    #[arg(long, conflicts_with = "password")]
    pub key: Option<String>,

    /// Use manually specified ports instead of automatic ones.
    #[arg(long, default_value_t = false)]
    pub manual_ports: bool,

    /// Core protocol port (only used with --manual-ports).
    #[arg(long)]
    pub core_port: Option<u16>,

    /// Auxiliary / WARP port (only used with --manual-ports).
    #[arg(long)]
    pub warp_port: Option<u16>,

    /// Local SOCKS listen port (only used with --manual-ports).
    #[arg(long)]
    pub listen_port: Option<u16>,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.command {
        Commands::Protocols => {
            for p in protocol::Protocol::all() {
                println!("{}", p.as_str());
            }
            Ok(())
        }
        Commands::Deploy(args) => run_deploy(args),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("deploy-manager: error: {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn run_deploy(args: DeployArgs) -> anyhow::Result<()> {
    let proto = protocol::Protocol::parse(&args.protocol)?;

    let ports = if args.manual_ports {
        protocol::Ports {
            core: args.core_port,
            warp: args.warp_port,
            listen: args.listen_port,
        }
    } else {
        protocol::Ports::automatic(proto)
    };

    println!("[deploy] protocol={}", proto.as_str());
    println!("[deploy] host={} ssh_port={} user={}", args.host, args.ssh_port, args.user);
    if let Some(k) = &args.key {
        println!("[deploy] auth=key file={k}");
    } else if args.password.is_some() {
        println!("[deploy] auth=password");
    } else {
        println!("[deploy] auth=agent");
    }

    deploy::deploy(&args, proto, &ports)
}