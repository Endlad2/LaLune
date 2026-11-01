// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Отдельная UID позволяет маршрутизировать транспорт ядра через обычную сеть.
use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};

pub struct CoreUser {
    pub uid: u32,
    directory: PathBuf,
    _lease: File,
}

impl CoreUser {
    pub fn prepare(source: &Path) -> Result<Self> {
        if unsafe { libc::geteuid() } != 0 {
            bail!("Для Linux TUN запустите backend от root: нужны TUN, смена UID и ip rule");
        }
        let lease = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(std::env::temp_dir().join("lalune-network.lock"))?;
        let metadata = lease.metadata()?;
        if metadata.uid() != 0 || metadata.mode() & 0o077 != 0 {
            bail!("Небезопасные права файла блокировки LaLune");
        }
        if unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            bail!("Другая сессия LaLune уже использует Linux TUN");
        }
        let mut used = HashSet::new();
        for line in fs::read_to_string("/etc/passwd")?.lines() {
            used.extend(
                line.split(':')
                    .skip(2)
                    .take(2)
                    .filter_map(|s| s.parse::<u32>().ok()),
            );
        }
        for line in fs::read_to_string("/etc/group")?.lines() {
            if let Some(gid) = line.split(':').nth(2).and_then(|s| s.parse::<u32>().ok()) {
                used.insert(gid);
            }
        }
        for entry in fs::read_dir("/proc")?.flatten() {
            if entry.file_name().to_string_lossy().parse::<u32>().is_err() {
                continue;
            }
            if let Ok(status) = fs::read_to_string(entry.path().join("status")) {
                for line in status.lines().filter(|l| {
                    l.starts_with("Uid:") || l.starts_with("Gid:") || l.starts_with("Groups:")
                }) {
                    used.extend(
                        line.split_whitespace()
                            .skip(1)
                            .filter_map(|s| s.parse::<u32>().ok()),
                    );
                }
            }
        }
        let uid = (61062..62062)
            .find(|uid| !used.contains(uid))
            .context("Нет свободной UID для ядра LaLune")?;
        let directory = std::env::temp_dir().join(format!("lalune-core-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&directory)?;
        let user = Self {
            uid,
            directory,
            _lease: lease,
        };
        fs::set_permissions(&user.directory, fs::Permissions::from_mode(0o755))?;
        fs::copy(source, user.executable()).context("Копирование ядра во временный каталог")?;
        fs::set_permissions(user.executable(), fs::Permissions::from_mode(0o555))?;
        fs::create_dir(user.workdir())?;
        fs::set_permissions(user.workdir(), fs::Permissions::from_mode(0o700))?;
        std::os::unix::fs::chown(user.workdir(), Some(uid), Some(uid))?;
        let profile = std::env::current_dir()?.join("vk_profile.json");
        if profile.exists() {
            let dest = user.workdir().join("vk_profile.json");
            fs::copy(profile, &dest)?;
            std::os::unix::fs::chown(dest, Some(uid), Some(uid))?;
        }
        Ok(user)
    }

    pub fn executable(&self) -> PathBuf {
        self.directory.join("core")
    }
    pub fn workdir(&self) -> PathBuf {
        self.directory.join("work")
    }

    pub fn configure(&self, command: &mut tokio::process::Command, args: &[String]) -> Result<()> {
        let mut args = args.to_vec();
        // Файлы, доступные root, могут лежать в закрытом домашнем каталоге.
        for i in 0..args.len().saturating_sub(1) {
            if args[i] == "--domains-file" {
                let dest = self.workdir().join(format!("domains-{i}.txt"));
                fs::copy(&args[i + 1], &dest).context("Копирование списка доменов для ядра")?;
                std::os::unix::fs::chown(&dest, Some(self.uid), Some(self.uid))?;
                args[i + 1] = dest.to_string_lossy().into_owned();
            }
        }
        command
            .args(args)
            .current_dir(self.workdir())
            .env("HOME", self.workdir())
            .kill_on_drop(true);
        let uid = self.uid;
        // Все три операции выполняются до exec и до потери root-привилегий.
        unsafe {
            command.as_std_mut().pre_exec(move || {
                if libc::setgroups(0, std::ptr::null()) != 0
                    || libc::setgid(uid) != 0
                    || libc::setuid(uid) != 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        Ok(())
    }
}

impl Drop for CoreUser {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.directory) {
            log::warn!("Не удалось удалить временный каталог ядра: {error}");
        }
    }
}
