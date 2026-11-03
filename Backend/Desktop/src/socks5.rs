// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Desktop SOCKS5 frontend for CSQTT/CSQTTR raw-IP tunnel.
//
// Unlike a normal SOCKS proxy, outbound sockets are bound to the tunnel IPv4
// and every destination gets a host route through the service TUN/Wintun.
// Therefore TCP CONNECT and UDP ASSOCIATE really traverse the core's local
// UDP raw-IP transport instead of escaping through the physical interface.

use anyhow::{anyhow, bail, Context, Result};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpSocket, TcpStream, UdpSocket};
use tokio::time::timeout;

use crate::events::Event;
use crate::state::AppState;

#[derive(Debug, Clone)]
enum TargetHost {
    Ip(Ipv4Addr),
    Domain(String),
}

#[derive(Debug, Clone)]
struct Target {
    host: TargetHost,
    port: u16,
}

/// Starts a SOCKS5 endpoint on a random free port.
///
/// `bind_all = false` -> 127.0.0.1 only.
/// `bind_all = true`  -> 0.0.0.0 for LAN sharing.
pub fn start(state: Arc<AppState>, bind_all: bool) -> Result<u16> {
    {
        let guard = state.socks5.lock();
        if guard.is_some() {
            state.log("[PROXY] already running");
            return Ok(*state.socks5_port.read());
        }
    }

    let bind_ip = if bind_all {
        Ipv4Addr::UNSPECIFIED
    } else {
        Ipv4Addr::LOCALHOST
    };
    let std_listener = std::net::TcpListener::bind((bind_ip, 0))
        .map_err(|e| anyhow!("socks5 bind {}: {}", bind_ip, e))?;
    std_listener
        .set_nonblocking(true)
        .map_err(|e| anyhow!("socks5 set_nonblocking: {}", e))?;
    let port = std_listener
        .local_addr()
        .map_err(|e| anyhow!("socks5 local_addr: {}", e))?
        .port();

    let tokio_listener = TcpListener::from_std(std_listener)
        .map_err(|e| anyhow!("socks5 from_std: {}", e))?;

    *state.socks5_port.write() = port;
    let shown_host = if bind_all { "0.0.0.0" } else { "127.0.0.1" };
    state.log(format!("[PROXY] Listening tunneled SOCKS5 on {}:{}", shown_host, port));
    state.events.emit(Event::named(
        "socks5_ready",
        serde_json::json!({
            "host": shown_host,
            "port": port,
            "shared": bind_all,
        }),
    ));

    if bind_all {
        let real_ip = local_ip_address().unwrap_or_else(|| "0.0.0.0".to_string());
        state.log(format!("[PROXY] LAN address: {}:{}", real_ip, port));
    }

    let state2 = state.clone();
    let handle = tokio::spawn(async move {
        loop {
            match tokio_listener.accept().await {
                Ok((client, peer)) => {
                    let st = state2.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_client(client, peer, st.clone(), bind_all).await {
                            st.log(format!("[PROXY] client {} error: {}", peer, e));
                        }
                    });
                }
                Err(e) => {
                    state2.log(format!("[PROXY] accept error: {}", e));
                    break;
                }
            }
        }
    });

    *state.socks5.lock() = Some(handle);
    Ok(port)
}

pub fn stop(state: &Arc<AppState>) {
    let handle = { state.socks5.lock().take() };
    if let Some(h) = handle {
        h.abort();
        state.log("[PROXY] stopped");
    }
    *state.socks5_port.write() = 0;
}

fn local_ip_address() -> Option<String> {
    use std::net::UdpSocket as StdUdpSocket;
    let socket = StdUdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    let ip = addr.ip();
    if ip.is_loopback() { None } else { Some(ip.to_string()) }
}

async fn handle_client(
    mut client: TcpStream,
    peer: SocketAddr,
    state: Arc<AppState>,
    bind_all: bool,
) -> Result<()> {
    negotiate(&mut client).await?;
    let (cmd, target) = read_request(&mut client).await?;

    match cmd {
        0x01 => handle_connect(client, target, state).await,
        0x03 => handle_udp_associate(client, peer, target, state, bind_all).await,
        other => {
            send_reply(&mut client, 0x07, SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)).await?;
            bail!("unsupported SOCKS5 command {}", other)
        }
    }
}

async fn negotiate(client: &mut TcpStream) -> Result<()> {
    let mut header = [0u8; 2];
    client.read_exact(&mut header).await?;
    if header[0] != 0x05 {
        bail!("unsupported SOCKS version {}", header[0]);
    }
    let mut methods = vec![0u8; header[1] as usize];
    client.read_exact(&mut methods).await?;
    if !methods.contains(&0x00) {
        client.write_all(&[0x05, 0xFF]).await?;
        bail!("client does not allow no-auth SOCKS5");
    }
    client.write_all(&[0x05, 0x00]).await?;
    Ok(())
}

async fn read_request(client: &mut TcpStream) -> Result<(u8, Target)> {
    let mut req = [0u8; 4];
    client.read_exact(&mut req).await?;
    if req[0] != 0x05 || req[2] != 0x00 {
        bail!("bad SOCKS5 request header");
    }
    let host = match req[3] {
        0x01 => {
            let mut addr = [0u8; 4];
            client.read_exact(&mut addr).await?;
            TargetHost::Ip(Ipv4Addr::from(addr))
        }
        0x03 => {
            let mut len = [0u8; 1];
            client.read_exact(&mut len).await?;
            if len[0] == 0 {
                bail!("empty SOCKS5 domain");
            }
            let mut domain = vec![0u8; len[0] as usize];
            client.read_exact(&mut domain).await?;
            TargetHost::Domain(String::from_utf8(domain).context("SOCKS5 domain is not UTF-8")?)
        }
        0x04 => {
            let mut addr = [0u8; 16];
            client.read_exact(&mut addr).await?;
            let mut port = [0u8; 2];
            client.read_exact(&mut port).await?;
            send_reply(
                client,
                0x08,
                SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
            )
            .await?;
            bail!("IPv6 SOCKS5 targets are not supported by the current IPv4 tunnel")
        }
        other => bail!("unknown SOCKS5 ATYP {}", other),
    };

    let mut port = [0u8; 2];
    client.read_exact(&mut port).await?;
    Ok((req[1], Target { host, port: u16::from_be_bytes(port) }))
}

async fn resolve_target(state: &Arc<AppState>, target: &Target) -> Result<SocketAddr> {
    let ip = match &target.host {
        TargetHost::Ip(ip) => *ip,
        TargetHost::Domain(domain) => resolve_a_via_tunnel(state, domain).await?,
    };
    crate::vpn::ensure_proxy_route(&state.vpn, IpAddr::V4(ip), &state.events)?;
    Ok(SocketAddr::new(IpAddr::V4(ip), target.port))
}

async fn handle_connect(
    mut client: TcpStream,
    target: Target,
    state: Arc<AppState>,
) -> Result<()> {
    let target_addr = match resolve_target(&state, &target).await {
        Ok(v) => v,
        Err(e) => {
            send_reply(
                &mut client,
                0x04,
                SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
            )
            .await?;
            return Err(e);
        }
    };

    let tunnel_ip = crate::vpn::tunnel_ipv4(&state.vpn)?;
    let socket = TcpSocket::new_v4()?;
    socket.bind(SocketAddr::new(IpAddr::V4(tunnel_ip), 0))?;
    let mut remote = match timeout(Duration::from_secs(15), socket.connect(target_addr)).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(e)) => {
            send_reply(
                &mut client,
                0x05,
                SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
            )
            .await?;
            return Err(anyhow!("connect to {} failed: {}", target_addr, e));
        }
        Err(_) => {
            send_reply(
                &mut client,
                0x06,
                SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
            )
            .await?;
            bail!("connect to {} timed out", target_addr);
        }
    };

    let bound = remote
        .local_addr()
        .unwrap_or_else(|_| SocketAddr::new(IpAddr::V4(tunnel_ip), 0));
    send_reply(&mut client, 0x00, bound).await?;

    let _ = tokio::io::copy_bidirectional(&mut client, &mut remote).await?;
    Ok(())
}

async fn handle_udp_associate(
    mut control: TcpStream,
    peer: SocketAddr,
    _requested: Target,
    state: Arc<AppState>,
    bind_all: bool,
) -> Result<()> {
    let relay_bind_ip = if bind_all {
        Ipv4Addr::UNSPECIFIED
    } else {
        Ipv4Addr::LOCALHOST
    };
    let relay = UdpSocket::bind((relay_bind_ip, 0)).await?;
    let relay_port = relay.local_addr()?.port();

    let advertised_ip = if bind_all {
        match control.local_addr()?.ip() {
            IpAddr::V4(ip) if !ip.is_unspecified() => ip,
            _ => local_ip_address()
                .and_then(|v| v.parse::<Ipv4Addr>().ok())
                .unwrap_or(Ipv4Addr::UNSPECIFIED),
        }
    } else {
        Ipv4Addr::LOCALHOST
    };
    send_reply(
        &mut control,
        0x00,
        SocketAddr::new(IpAddr::V4(advertised_ip), relay_port),
    )
    .await?;

    let tunnel_ip = crate::vpn::tunnel_ipv4(&state.vpn)?;
    let outbound = UdpSocket::bind((tunnel_ip, 0)).await?;
    let mut client_udp: Option<SocketAddr> = None;
    let mut relay_buf = vec![0u8; 65535];
    let mut remote_buf = vec![0u8; 65535];
    let mut control_probe = [0u8; 1];

    loop {
        tokio::select! {
            result = control.read(&mut control_probe) => {
                match result {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
            result = relay.recv_from(&mut relay_buf) => {
                let (n, from) = result?;
                if from.ip() != peer.ip() {
                    continue;
                }
                if client_udp.is_none() {
                    client_udp = Some(from);
                }
                let (target, payload_offset) = match parse_udp_request(&relay_buf[..n]) {
                    Ok(v) => v,
                    Err(e) => {
                        state.log(format!("[PROXY] bad UDP ASSOCIATE packet: {}", e));
                        continue;
                    }
                };
                let target_addr = match resolve_target(&state, &target).await {
                    Ok(v) => v,
                    Err(e) => {
                        state.log(format!("[PROXY] UDP target resolve failed: {}", e));
                        continue;
                    }
                };
                if let Err(e) = outbound.send_to(&relay_buf[payload_offset..n], target_addr).await {
                    state.log(format!("[PROXY] UDP send {}: {}", target_addr, e));
                }
            }
            result = outbound.recv_from(&mut remote_buf) => {
                let (n, from) = result?;
                let Some(client_addr) = client_udp else { continue; };
                let packet = build_udp_reply(from, &remote_buf[..n])?;
                let _ = relay.send_to(&packet, client_addr).await;
            }
        }
    }
    Ok(())
}

fn parse_udp_request(packet: &[u8]) -> Result<(Target, usize)> {
    if packet.len() < 4 || packet[0] != 0 || packet[1] != 0 {
        bail!("invalid UDP RSV");
    }
    if packet[2] != 0 {
        bail!("fragmented SOCKS5 UDP is not supported");
    }
    let mut offset = 4;
    let host = match packet[3] {
        0x01 => {
            if packet.len() < offset + 4 + 2 { bail!("short IPv4 UDP request"); }
            let ip = Ipv4Addr::new(
                packet[offset],
                packet[offset + 1],
                packet[offset + 2],
                packet[offset + 3],
            );
            offset += 4;
            TargetHost::Ip(ip)
        }
        0x03 => {
            if packet.len() <= offset { bail!("short domain UDP request"); }
            let len = packet[offset] as usize;
            offset += 1;
            if packet.len() < offset + len + 2 { bail!("short domain UDP request"); }
            let domain = String::from_utf8(packet[offset..offset + len].to_vec())
                .context("UDP domain is not UTF-8")?;
            offset += len;
            TargetHost::Domain(domain)
        }
        0x04 => bail!("IPv6 UDP targets are not supported"),
        atyp => bail!("unknown UDP ATYP {}", atyp),
    };
    if packet.len() < offset + 2 { bail!("missing UDP target port"); }
    let port = u16::from_be_bytes([packet[offset], packet[offset + 1]]);
    offset += 2;
    Ok((Target { host, port }, offset))
}

fn build_udp_reply(from: SocketAddr, payload: &[u8]) -> Result<Vec<u8>> {
    let SocketAddr::V4(v4) = from else {
        bail!("IPv6 UDP reply is not supported");
    };
    let mut out = Vec::with_capacity(10 + payload.len());
    out.extend_from_slice(&[0, 0, 0, 0x01]);
    out.extend_from_slice(&v4.ip().octets());
    out.extend_from_slice(&v4.port().to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

async fn send_reply(client: &mut TcpStream, rep: u8, bound: SocketAddr) -> Result<()> {
    let (ip, port) = match bound {
        SocketAddr::V4(v4) => (*v4.ip(), v4.port()),
        SocketAddr::V6(_) => (Ipv4Addr::UNSPECIFIED, 0),
    };
    let mut reply = Vec::with_capacity(10);
    reply.extend_from_slice(&[0x05, rep, 0x00, 0x01]);
    reply.extend_from_slice(&ip.octets());
    reply.extend_from_slice(&port.to_be_bytes());
    client.write_all(&reply).await?;
    Ok(())
}

async fn resolve_a_via_tunnel(state: &Arc<AppState>, domain: &str) -> Result<Ipv4Addr> {
    if domain.is_empty() || domain.len() > 253 {
        bail!("invalid domain length");
    }
    let dns = crate::vpn::tunnel_dns_ipv4(&state.vpn)
        .ok_or_else(|| anyhow!("no IPv4 DNS from TUNCONF"))?;
    crate::vpn::ensure_proxy_route(&state.vpn, IpAddr::V4(dns), &state.events)?;

    let tunnel_ip = crate::vpn::tunnel_ipv4(&state.vpn)?;
    let socket = UdpSocket::bind((tunnel_ip, 0)).await?;
    let dns_addr = SocketAddr::new(IpAddr::V4(dns), 53);

    let id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u16;
    let query = build_dns_query(id, domain)?;
    socket.send_to(&query, dns_addr).await?;

    let mut buf = [0u8; 2048];
    let (n, _) = timeout(Duration::from_secs(5), socket.recv_from(&mut buf))
        .await
        .map_err(|_| anyhow!("DNS timeout for {}", domain))??;
    parse_dns_a_response(&buf[..n], id)
        .ok_or_else(|| anyhow!("DNS returned no A record for {}", domain))
}

fn build_dns_query(id: u16, domain: &str) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(512);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&0x0100u16.to_be_bytes()); // recursion desired
    out.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // ANCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // NSCOUNT
    out.extend_from_slice(&0u16.to_be_bytes()); // ARCOUNT
    for label in domain.trim_end_matches('.').split('.') {
        if label.is_empty() || label.len() > 63 {
            bail!("invalid DNS label in {}", domain);
        }
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    out.extend_from_slice(&1u16.to_be_bytes()); // A
    out.extend_from_slice(&1u16.to_be_bytes()); // IN
    Ok(out)
}

fn parse_dns_a_response(packet: &[u8], expected_id: u16) -> Option<Ipv4Addr> {
    if packet.len() < 12 { return None; }
    if u16::from_be_bytes([packet[0], packet[1]]) != expected_id { return None; }
    let flags = u16::from_be_bytes([packet[2], packet[3]]);
    if flags & 0x8000 == 0 || flags & 0x000F != 0 { return None; }
    let qd = u16::from_be_bytes([packet[4], packet[5]]) as usize;
    let an = u16::from_be_bytes([packet[6], packet[7]]) as usize;
    let mut offset = 12;

    for _ in 0..qd {
        offset = skip_dns_name(packet, offset)?;
        if packet.len() < offset + 4 { return None; }
        offset += 4;
    }

    for _ in 0..an {
        offset = skip_dns_name(packet, offset)?;
        if packet.len() < offset + 10 { return None; }
        let typ = u16::from_be_bytes([packet[offset], packet[offset + 1]]);
        let class = u16::from_be_bytes([packet[offset + 2], packet[offset + 3]]);
        let rdlen = u16::from_be_bytes([packet[offset + 8], packet[offset + 9]]) as usize;
        offset += 10;
        if packet.len() < offset + rdlen { return None; }
        if typ == 1 && class == 1 && rdlen == 4 {
            return Some(Ipv4Addr::new(
                packet[offset],
                packet[offset + 1],
                packet[offset + 2],
                packet[offset + 3],
            ));
        }
        offset += rdlen;
    }
    None
}

fn skip_dns_name(packet: &[u8], mut offset: usize) -> Option<usize> {
    loop {
        let len = *packet.get(offset)?;
        if len & 0xC0 == 0xC0 {
            if packet.get(offset + 1).is_some() {
                return Some(offset + 2);
            }
            return None;
        }
        offset += 1;
        if len == 0 {
            return Some(offset);
        }
        if len & 0xC0 != 0 {
            return None;
        }
        offset = offset.checked_add(len as usize)?;
        if offset > packet.len() {
            return None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn udp_request_ipv4_parses() {
        let packet = [
            0, 0, 0, 1,
            1, 2, 3, 4,
            0x01, 0xBB,
            9, 8, 7,
        ];
        let (target, offset) = parse_udp_request(&packet).unwrap();
        assert_eq!(offset, 10);
        assert_eq!(target.port, 443);
        match target.host {
            TargetHost::Ip(ip) => assert_eq!(ip, Ipv4Addr::new(1, 2, 3, 4)),
            _ => panic!("unexpected host"),
        }
    }

    #[test]
    fn dns_query_has_question() {
        let packet = build_dns_query(0x1234, "example.com").unwrap();
        assert_eq!(&packet[..2], &[0x12, 0x34]);
        assert!(packet.windows(7).any(|w| w == b"example"));
    }
}
