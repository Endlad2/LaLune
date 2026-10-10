// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SOCKS5-прокси на 0.0.0.0:1080 для раздачи VPN.
//
// Логика: если включена настройка share_vpn, бэкенд поднимает
// SOCKS5-сервер. Все входящие соединения идут через TUN-интерфейс
// (так как default route уже указывает на csqtt0).
//
// Поддерживается только CONNECT (без BIND и UDP ASSOCIATE).

use anyhow::{anyhow, Result};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::events::Event;
use crate::state::AppState;

pub const SOCKS5_PORT: u16 = 1080;

/// Запустить SOCKS5-сервер. Сохраняет handle в state, чтобы потом
/// можно было остановить.
pub fn start(state: Arc<AppState>) -> Result<()> {
    // Не запускаем второй экземпляр.
    {
        let guard = state.socks5.lock();
        if guard.is_some() {
            state.log("[PROXY] already running");
            return Ok(());
        }
    }

    // Определяем реальный IP устройства (не 127.0.0.1).
    let real_ip = local_ip_address()
        .unwrap_or_else(|| "0.0.0.0".to_string());

    let state2 = state.clone();
    let handle = tokio::spawn(async move {
        let addr = SocketAddr::from(([0, 0, 0, 0], SOCKS5_PORT));
        let listener = match TcpListener::bind(addr).await {
            Ok(l) => l,
            Err(e) => {
                state2.log(format!("[PROXY] bind failed: {}", e));
                return;
            }
        };

        state2.log(format!("[PROXY] Listening socks5 on {}:{}", real_ip, SOCKS5_PORT));
        state2.events.emit(Event::log(format!(
            "[PROXY] Listening socks5 on {}:{}",
            real_ip, SOCKS5_PORT
        )));

        loop {
            match listener.accept().await {
                Ok((client, peer)) => {
                    let st = state2.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_client(client).await {
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
    Ok(())
}

/// Остановить SOCKS5-сервер.
pub fn stop(state: &Arc<AppState>) {
    let handle = { state.socks5.lock().take() };
    if let Some(h) = handle {
        h.abort();
        state.log("[PROXY] stopped");
    }
}

/// Определить локальный IP (не loopback). Пытаемся через UDP-соединение
/// к внешнему адресу — маршрутизация подскажет наш исходящий IP.
fn local_ip_address() -> Option<String> {
    use std::net::UdpSocket;
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    let ip = addr.ip();
    if ip.is_loopback() {
        None
    } else {
        Some(ip.to_string())
    }
}

// ============================================================
//  SOCKS5 protocol
// ============================================================

async fn handle_client(mut client: TcpStream) -> Result<()> {
    // --- 1. Greeting: version + nmethods + methods ---
    let mut header = [0u8; 2];
    client.read_exact(&mut header).await?;
    if header[0] != 0x05 {
        return Err(anyhow!("unsupported SOCKS version {}", header[0]));
    }
    let nmethods = header[1] as usize;
    let mut methods = vec![0u8; nmethods];
    client.read_exact(&mut methods).await?;

    // Отвечаем: "no auth required"
    client.write_all(&[0x05, 0x00]).await?;

    // --- 2. Request: version + cmd + rsv + atyp + addr + port ---
    let mut req = [0u8; 4];
    client.read_exact(&mut req).await?;
    if req[0] != 0x05 {
        return Err(anyhow!("bad request version {}", req[0]));
    }
    if req[1] != 0x01 {
        // Только CONNECT
        client.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        return Err(anyhow!("unsupported command {}", req[1]));
    }

    let target = match req[3] {
        0x01 => {
            // IPv4
            let mut addr = [0u8; 4];
            client.read_exact(&mut addr).await?;
            let mut port = [0u8; 2];
            client.read_exact(&mut port).await?;
            let ip = Ipv4Addr::new(addr[0], addr[1], addr[2], addr[3]);
            SocketAddr::new(IpAddr::V4(ip), u16::from_be_bytes(port))
        }
        0x03 => {
            // Domain name
            let mut len = [0u8; 1];
            client.read_exact(&mut len).await?;
            let mut domain = vec![0u8; len[0] as usize];
            client.read_exact(&mut domain).await?;
            let mut port = [0u8; 2];
            client.read_exact(&mut port).await?;
            let host = String::from_utf8_lossy(&domain).to_string();
            let port = u16::from_be_bytes(port);
            // Резолвим домен через системный DNS (он сейчас указывает на 8.8.8.8,
            // что пойдёт через TUN).
            let addr_str = format!("{}:{}", host, port);
            let mut addrs = tokio::net::lookup_host(&addr_str).await?;
            addrs.next().ok_or_else(|| anyhow!("cannot resolve {}", host))?
        }
        0x04 => {
            // IPv6
            let mut addr = [0u8; 16];
            client.read_exact(&mut addr).await?;
            let mut port = [0u8; 2];
            client.read_exact(&mut port).await?;
            let ip = std::net::Ipv6Addr::from(addr);
            SocketAddr::new(IpAddr::V6(ip), u16::from_be_bytes(port))
        }
        other => {
            return Err(anyhow!("unknown ATYP {}", other));
        }
    };

    // --- 3. Подключаемся к цели (через TUN, так как default route — csqtt0) ---
    let remote = match TcpStream::connect(target).await {
        Ok(s) => s,
        Err(e) => {
            // Отвечаем "connection refused"
            client.write_all(&[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Err(anyhow!("connect to {} failed: {}", target, e));
        }
    };

    // --- 4. Успешный ответ ---
    client
        .write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await?;

    // --- 5. Двунаправленный копир ---
    let (mut cr, mut cw) = client.split();
    let (mut rr, mut rw) = remote.split();

    let a = tokio::io::copy(&mut cr, &mut rw);
    let b = tokio::io::copy(&mut rr, &mut cw);

    tokio::select! {
        _ = a => {},
        _ = b => {},
    }

    Ok(())
}
