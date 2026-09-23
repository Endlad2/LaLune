// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Protocol registry for the deploy manager. Maps a protocol name to:
//   * the canonical core binary name,
//   * the GitHub release repository that hosts prebuilt cores,
//   * default automatic ports (used when --manual-ports is not given),
//   * the remote install script that fetches and starts the core.

use anyhow::{bail, Result};

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Protocol {
    Csqtt,
    FreeTurn,
    OlcRtc,
    OpenFlux,
    Tots,
}

impl Protocol {
    pub fn all() -> [Protocol; 5] {
        [
            Protocol::Csqtt,
            Protocol::FreeTurn,
            Protocol::OlcRtc,
            Protocol::OpenFlux,
            Protocol::Tots,
        ]
    }

    pub fn parse(s: &str) -> Result<Protocol> {
        match s.trim().to_ascii_lowercase().as_str() {
            "csqtt" | "lalune" => Ok(Protocol::Csqtt),
            "freeturn" | "free-turn" | "free_turn" | "ftp" => Ok(Protocol::FreeTurn),
            "olcrtc" | "olc" => Ok(Protocol::OlcRtc),
            "openflux" | "open-flux" | "of" => Ok(Protocol::OpenFlux),
            "tots" => Ok(Protocol::Tots),
            other => bail!("unknown protocol: {other}"),
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Protocol::Csqtt => "csqtt",
            Protocol::FreeTurn => "freeturn",
            Protocol::OlcRtc => "olcrtc",
            Protocol::OpenFlux => "openflux",
            Protocol::Tots => "tots",
        }
    }

    /// Canonical binary name of the core on the remote host.
    pub fn core_binary(&self) -> &'static str {
        match self {
            Protocol::Csqtt => "csqtt-core",
            Protocol::FreeTurn => "free-turn-proxy",
            Protocol::OlcRtc => "olcrtc",
            Protocol::OpenFlux => "openflux",
            Protocol::Tots => "tots-cli",
        }
    }

    /// GitHub release repository for prebuilt cores.
    pub fn release_repo(&self) -> &'static str {
        match self {
            Protocol::Csqtt => "Endlad2/csqtt-core",
            Protocol::FreeTurn => "Endlad2/free-turn-proxy-core",
            Protocol::OlcRtc => "Endlad2/olcrtc-core",
            Protocol::OpenFlux => "Endlad2/OpenFlux-core",
            Protocol::Tots => "Endlad2/ToTS",
        }
    }
}

/// Ports passed to the deployed core.
#[derive(Copy, Clone, Debug, Default)]
pub struct Ports {
    pub core: Option<u16>,
    pub warp: Option<u16>,
    pub listen: Option<u16>,
}

impl Ports {
    /// Sensible automatic ports per protocol (used without --manual-ports).
    pub fn automatic(proto: Protocol) -> Ports {
        let (core, warp, listen) = match proto {
            Protocol::Csqtt => (443, 0, 1080),
            Protocol::FreeTurn => (50000, 50001, 1080),
            Protocol::OlcRtc => (45000, 0, 1080),
            Protocol::OpenFlux => (8080, 0, 1080),
            Protocol::Tots => (9000, 9001, 1080),
        };
        Ports {
            core: Some(core),
            warp: if warp == 0 { None } else { Some(warp) },
            listen: Some(listen),
        }
    }

    pub fn flags(&self) -> String {
        let mut out = String::new();
        if let Some(p) = self.core {
            out.push_str(&format!(" --port {p}"));
        }
        if let Some(p) = self.warp {
            out.push_str(&format!(" --warp-port {p}"));
        }
        if let Some(p) = self.listen {
            out.push_str(&format!(" --listen {p}"));
        }
        out
    }
}