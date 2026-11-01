// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
use anyhow::{bail, Context, Result};
use std::fs;
use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UdpSocket;
use tokio::task::JoinHandle;

use crate::events::{Event, EventBus};

const TABLE: &str = "10620";
const PRIORITIES: [u32; 3] = [10620, 10621, 10622];

fn ip(args: &[String]) -> Result<String> {
    let output = Command::new("ip")
        .args(args)
        .output()
        .context("Не удалось запустить ip; на OpenWrt требуется ip-full")?;
    if !output.status.success() {
        bail!(
            "ip {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| (*s).to_owned()).collect()
}

struct Routes {
    undo: Vec<Vec<String>>,
    dns: Option<(PathBuf, Vec<u8>, Vec<u8>)>,
    events: EventBus,
}

impl Routes {
    fn install(name: &str, dns: &str, uid: u32, events: EventBus) -> Result<Self> {
        let installed = dns_content(dns)?;
        let mut routes = Self {
            undo: Vec::new(),
            dns: None,
            events,
        };
        if uid != 0 {
            let rules = ip(&strings(&["-N", "-4", "rule", "show"]))?;
            for line in rules.lines() {
                let priority = line
                    .split(':')
                    .next()
                    .and_then(|s| s.trim().parse::<u32>().ok());
                if priority.is_some_and(|p| PRIORITIES.contains(&p))
                    || line.contains(&format!("lookup {TABLE}"))
                {
                    bail!("Таблица или приоритеты маршрутизации LaLune уже заняты");
                }
            }
            let all = ip(&strings(&["-N", "-4", "route", "show", "table", "all"]))?;
            if all.lines().any(|line| {
                line.split_whitespace()
                    .collect::<Vec<_>>()
                    .windows(2)
                    .any(|w| w == ["table", TABLE])
            }) {
                bail!("Таблица маршрутизации {TABLE} уже занята");
            }
            routes.add(strings(&[
                "-4", "route", "add", "default", "dev", name, "table", TABLE,
            ]))?;
            routes.add(strings(&[
                "-4",
                "rule",
                "add",
                "priority",
                "10620",
                "uidrange",
                &format!("{uid}-{uid}"),
                "lookup",
                "main",
            ]))?;
            routes.add(strings(&[
                "-4",
                "rule",
                "add",
                "priority",
                "10621",
                "lookup",
                "main",
                "suppress_prefixlength",
                "0",
            ]))?;
            routes.add(strings(&[
                "-4", "rule", "add", "priority", "10622", "lookup", TABLE,
            ]))?;
        } else {
            // Смена UID/policy routing относится только к CSQTT. Другие ядра
            // сохраняют прежние пути, права и способ настройки маршрута.
            if let Err(error) = routes.add(strings(&["-4", "route", "add", "default", "dev", name])) {
                routes.events.emit(Event::error(error.to_string()));
            }
        }
        let path = PathBuf::from("/etc/resolv.conf");
        let previous = fs::read(&path).context("Чтение исходного resolv.conf")?;
        // Запись через существующий путь сохраняет симлинк resolv.conf.
        if let Err(error) = fs::write(&path, &installed) {
            fs::write(&path, &previous).context("Откат неудавшейся записи DNS")?;
            return Err(error).context("Настройка DNS для TUN");
        }
        routes.dns = Some((path, previous, installed));
        Ok(routes)
    }

    fn add(&mut self, args: Vec<String>) -> Result<()> {
        ip(&args)?;
        let mut undo = args;
        undo[2] = "del".into();
        self.undo.push(undo);
        Ok(())
    }
}

impl Drop for Routes {
    fn drop(&mut self) {
        if let Some((path, previous, installed)) = &self.dns {
            if fs::read(path).ok().as_deref() == Some(installed.as_slice()) {
                if let Err(error) = fs::write(path, previous) {
                    self.events.emit(Event::error(format!(
                        "Не удалось восстановить DNS: {error}"
                    )));
                }
            }
        }
        for args in self.undo.iter().rev() {
            if let Err(error) = ip(args) {
                self.events.emit(Event::error(format!(
                    "Не удалось удалить маршрут LaLune: {error}"
                )));
            }
        }
    }
}

fn dns_content(dns: &str) -> Result<Vec<u8>> {
    let mut text = String::new();
    for address in dns.split(',').map(str::trim) {
        let ip: Ipv4Addr = address.parse().context("Некорректный IPv4-адрес DNS")?;
        text.push_str(&format!("nameserver {ip}\n"));
    }
    if text.is_empty() {
        bail!("Не указан DNS для TUN");
    }
    Ok(text.into_bytes())
}

pub struct Session {
    handle: Option<JoinHandle<()>>,
}

impl Session {
    pub fn start(
        name: &str,
        address: &str,
        dns: &str,
        mtu: u16,
        core_port: u16,
        uid: u32,
        running: Arc<AtomicBool>,
        rx: Arc<AtomicU64>,
        tx: Arc<AtomicU64>,
        events: EventBus,
    ) -> Result<Self> {
        let address: Ipv4Addr = address.parse().context("Некорректный адрес TUN")?;
        let mut config = tun::Configuration::default();
        config
            .name(name)
            .address(address)
            .netmask(Ipv4Addr::new(255, 255, 255, 255))
            .mtu(mtu as i32)
            .up();
        let dev = tun::create_as_async(&config)
            .context("Создание Linux TUN (нужны root и /dev/net/tun)")?;
        let socket = UdpSocket::from_std({
            let socket = std::net::UdpSocket::bind("127.0.0.1:0")?;
            socket.connect((Ipv4Addr::LOCALHOST, core_port))?;
            socket.set_nonblocking(true)?;
            socket
        })?;
        let routes = Routes::install(name, dns, uid, events.clone())?;
        rx.store(0, Ordering::Relaxed);
        tx.store(0, Ordering::Relaxed);
        running.store(true, Ordering::Release);
        let handle = tokio::spawn(async move {
            // Drop восстанавливает сеть и при штатном завершении, и при abort.
            let (mut reader, mut writer) = tokio::io::split(dev);
            let _routes = routes;
            let mut outgoing = vec![0u8; 65535];
            let mut incoming = vec![0u8; 65535];
            let result: Result<()> = async {
                loop {
                    tokio::select! {
                        result = reader.read(&mut outgoing) => {
                            let n = result?;
                            if n == 0 { bail!("TUN закрыт"); }
                            if socket.send(&outgoing[..n]).await? != n { bail!("Неполная отправка пакета ядру"); }
                            tx.fetch_add(n as u64, Ordering::Relaxed);
                        }
                        result = socket.recv(&mut incoming) => {
                            let n = result?;
                            // Один write соответствует одному IP-пакету TUN.
                            if writer.write(&incoming[..n]).await? != n { bail!("Неполная запись пакета в TUN"); }
                            rx.fetch_add(n as u64, Ordering::Relaxed);
                        }
                    }
                }
            }.await;
            running.store(false, Ordering::Release);
            if let Err(error) = result {
                events.emit(Event::error(format!("TUN-мост остановлен: {error}")));
                events.emit(Event::status(false));
            }
        });
        Ok(Self {
            handle: Some(handle),
        })
    }

    pub async fn stop(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.abort();
            let _ = handle.await;
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(handle) = &self.handle {
            handle.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_dns_before_changing_network() {
        assert_eq!(
            dns_content("1.1.1.1, 8.8.8.8").unwrap(),
            b"nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
        );
        assert!(dns_content("1.1.1.1\nanything").is_err());
        assert!(dns_content("").is_err());
    }
}
