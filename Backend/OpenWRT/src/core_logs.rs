// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use flate2::{read::MultiGzDecoder, write::GzEncoder, Compression};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

pub const FILE_NAME: &str = "logs.log.gz";
pub const CORE_PREFIX: &str = "[CORE] ";
pub const MAX_LINE_BYTES: usize = 4 * 1024;
const SEGMENT_BYTES: usize = 64 * 1024;
const COMPRESSED_BYTES: u64 = (SEGMENT_BYTES + 1024) as u64;

pub struct CoreLogs {
    active: PathBuf,
    previous: PathBuf,
    legacy: PathBuf,
    active_bytes: usize,
    pending: VecDeque<String>,
    pending_bytes: usize,
}

impl CoreLogs {
    pub fn new(dir: &Path) -> Self {
        let active = dir.join(FILE_NAME);
        let active_bytes = match read_segment(&active) {
            Ok((data, true)) => data.len(),
            _ => SEGMENT_BYTES,
        };
        Self {
            active,
            previous: dir.join("logs.log.1.gz"),
            legacy: dir.join("logs.log"),
            active_bytes,
            pending: VecDeque::new(),
            pending_bytes: 0,
        }
    }

    pub fn record(&mut self, mut line: String) {
        if line.contains(['\r', '\n']) {
            line = line.replace(['\r', '\n'], " ");
        }
        if line.len() > MAX_LINE_BYTES {
            let mut end = MAX_LINE_BYTES - 3;
            while !line.is_char_boundary(end) {
                end -= 1;
            }
            line.truncate(end);
            line.push_str("...");
        }
        self.pending_bytes += line.len() + 1;
        while self.pending_bytes > SEGMENT_BYTES {
            if let Some(oldest) = self.pending.pop_front() {
                self.pending_bytes -= oldest.len() + 1;
            }
        }
        self.pending.push_back(line);
    }

    pub fn flush(&mut self) -> io::Result<()> {
        if self.pending.is_empty() {
            return Ok(());
        }
        // Each batch is a complete gzip member, readable while the core runs.
        let mut gzip = GzEncoder::new(Vec::new(), Compression::fast());
        for line in &self.pending {
            writeln!(gzip, "{line}")?;
        }
        let member = gzip.finish()?;

        let mut active_size = match fs::metadata(&self.active) {
            Ok(metadata) => metadata.len(),
            Err(err) if err.kind() == io::ErrorKind::NotFound => 0,
            Err(err) => return Err(err),
        };
        if active_size == 0 {
            self.active_bytes = 0;
        }
        if active_size + member.len() as u64 > COMPRESSED_BYTES
            || self.active_bytes + self.pending_bytes > SEGMENT_BYTES
        {
            fs::rename(&self.active, &self.previous)?;
            self.active_bytes = 0;
            active_size = 0;
        }

        let mut options = OpenOptions::new();
        options.append(true).create(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&self.active)?;
        if let Err(err) = file.write_all(&member) {
            if file.set_len(active_size).is_err() {
                self.active_bytes = SEGMENT_BYTES;
            }
            return Err(err);
        }
        self.active_bytes += self.pending_bytes;
        self.pending.clear();
        self.pending_bytes = 0;
        Ok(())
    }

    pub fn snapshot(&self) -> Vec<String> {
        let mut lines = Vec::new();
        for path in [&self.previous, &self.active] {
            if let Ok((data, _)) = read_segment(path) {
                lines.extend(String::from_utf8_lossy(&data).lines().map(str::to_owned));
            }
        }
        lines.extend(self.pending.iter().cloned());
        lines
    }

    pub fn clear(&mut self) -> io::Result<()> {
        self.pending.clear();
        self.pending_bytes = 0;
        // Attempt each removal even if one generation is inaccessible.
        let previous = remove(&self.previous);
        let active = remove(&self.active);
        let legacy = remove(&self.legacy);
        if active.is_ok() {
            self.active_bytes = 0;
        }
        previous.and(active).and(legacy)
    }

    pub fn migrate_legacy(&mut self) -> io::Result<()> {
        let mut file = match File::open(&self.legacy) {
            Ok(file) => file,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(err) => return Err(err),
        };
        let skip = file.metadata()?.len().saturating_sub(SEGMENT_BYTES as u64);
        file.seek(SeekFrom::Start(skip))?;
        let mut data = Vec::new();
        file.take(SEGMENT_BYTES as u64).read_to_end(&mut data)?;
        let text = String::from_utf8_lossy(&data);
        for line in text.lines().skip(usize::from(skip > 0)) {
            self.record(format!("{CORE_PREFIX}{line}"));
        }
        self.flush()?;
        remove(&self.legacy)
    }
}

fn remove(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

fn read_segment(path: &Path) -> io::Result<(Vec<u8>, bool)> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok((Vec::new(), true)),
        Err(err) => return Err(err),
    };
    let size = file.metadata()?.len();
    let mut data = Vec::new();
    let result = MultiGzDecoder::new(file.take(COMPRESSED_BYTES))
        .take(SEGMENT_BYTES as u64 + 1)
        .read_to_end(&mut data);
    let valid = result.is_ok() && data.len() <= SEGMENT_BYTES && size <= COMPRESSED_BYTES;
    if !valid {
        // Keep complete lines when a power loss interrupts a member append.
        data.truncate(SEGMENT_BYTES);
        data.truncate(data.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1));
    }
    Ok((data, valid))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("lalune-logs-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn persists_gzip_members_and_clears_disk_and_pending() {
        let dir = TestDir::new();
        let mut logs = CoreLogs::new(&dir.0);
        logs.record("[VPN] connecting".into());
        logs.flush().unwrap();
        logs.record("[CORE] started".into());
        assert_eq!(logs.snapshot(), ["[VPN] connecting", "[CORE] started"]);
        logs.flush().unwrap();
        let gzip = std::fs::read(&logs.active).unwrap();
        assert!(gzip.starts_with(&[0x1f, 0x8b]));

        let mut logs = CoreLogs::new(&dir.0);
        assert_eq!(logs.snapshot(), ["[VPN] connecting", "[CORE] started"]);
        logs.record("[CORE] unflushed".into());
        logs.clear().unwrap();
        assert!(logs.snapshot().is_empty());
        logs.flush().unwrap();
        assert!(!logs.active.exists());
    }

    #[test]
    fn rotates_even_highly_compressible_history() {
        let dir = TestDir::new();
        let mut logs = CoreLogs::new(&dir.0);
        for generation in 0..4 {
            for _ in 0..24 {
                logs.record(format!("{generation} {}", "x".repeat(3000)));
            }
            logs.flush().unwrap();
        }

        let lines = logs.snapshot();
        assert!(lines.first().unwrap().starts_with("2 "));
        assert!(lines.last().unwrap().starts_with("3 "));
        assert!(lines.iter().map(|line| line.len() + 1).sum::<usize>() <= 2 * SEGMENT_BYTES);
        assert_eq!(std::fs::read_dir(&dir.0).unwrap().count(), 2);
    }

    #[test]
    fn migrates_legacy_core_output() {
        let dir = TestDir::new();
        let legacy = dir.0.join("logs.log");
        std::fs::write(&legacy, b"starting\nready\n").unwrap();
        let mut logs = CoreLogs::new(&dir.0);
        logs.migrate_legacy().unwrap();
        assert!(!legacy.exists());
        assert_eq!(logs.snapshot(), ["[CORE] starting", "[CORE] ready"]);
    }
}
