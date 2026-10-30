//! Pool.swift and Watcher.swift: where the config directory is, loading a
//! domain, the atomic write `Config::store` uses, and the watch that wakes a
//! component when a file in the directory changes.
//!
//! Reads are `fs::read`-shaped rather than Swift's mmap: what matters is
//! that a reader holds the inode it opened, so an atomic rename underneath
//! hands it the whole old file, never a torn one, and a read of an open
//! descriptor holds it as a mapping does.

use crate::{Config, Error};
use abyss_sys::poolwatch::DirWatch;
use std::fs::{DirBuilder, File, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};

/// The config directory: `$ABYSS_CONFIG_DIR`, else `$XDG_CONFIG_HOME/abyss`,
/// else `$HOME/.config/abyss`. Created (with parents) if absent.
pub fn config_dir() -> Result<String, Error> {
    // Swift reads them with getenv and String(cString:): lenient UTF-8.
    let var = |k: &str| std::env::var_os(k).map(|v| v.to_string_lossy().into_owned());
    let dir = choose_config_dir(var("ABYSS_CONFIG_DIR").as_deref(), var("XDG_CONFIG_HOME").as_deref(), var("HOME").as_deref())
        .ok_or(Error::NoConfigDir)?;
    make_dirs(&dir)?;
    Ok(dir)
}

/// The precedence, without the environment. A variable that is set counts
/// even when it is empty, as Swift's `getenv` sees it: an empty
/// `ABYSS_CONFIG_DIR` is the directory "" (so files land in `/`).
fn choose_config_dir(abyss: Option<&str>, xdg: Option<&str>, home: Option<&str>) -> Option<String> {
    match (abyss, xdg, home) {
        (Some(d), _, _) => Some(d.to_owned()),
        (None, Some(x), _) => Some(format!("{x}/abyss")),
        (None, None, Some(h)) => Some(format!("{h}/.config/abyss")),
        (None, None, None) => None,
    }
}

fn resolve(dir: Option<&str>) -> Result<String, Error> {
    match dir {
        Some(d) => Ok(d.to_owned()),
        None => config_dir(),
    }
}

/// Load and parse `<domain>.ini` from `dir` (default: the config
/// directory). A missing or empty file is an empty Config, not an error.
pub fn load(domain: &str, dir: Option<&str>) -> Result<Config, Error> {
    let d = resolve(dir)?;
    match read(&format!("{d}/{domain}.ini"))? {
        Some(bytes) => Ok(Config::parse_bytes(&bytes)),
        None => Ok(Config::new()),
    }
}

/// The text of `path`, or None if it is missing or empty. Read to the size
/// it had when opened, as Swift maps it.
fn read(path: &str) -> Result<Option<Vec<u8>>, Error> {
    let mut f = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(io_error(format!("open {path}"), &e)),
    };
    let size = f.metadata().map_err(|_| Error::Io(format!("fstat {path}")))?.len();
    if size == 0 {
        return Ok(None);
    }
    let mut bytes = Vec::with_capacity(size as usize);
    (&mut f).take(size).read_to_end(&mut bytes).map_err(|e| io_error(format!("read {path}"), &e))?;
    Ok(Some(bytes))
}

/// temp file + fsync + atomic rename over `<domain>.ini`, serialized by an
/// exclusive flock on `<domain>.ini.lock`, then the directory fsynced so the
/// rename itself is durable (best effort). A reader always sees a whole
/// file.
pub(crate) fn atomic_write(dir: &str, domain: &str, bytes: &[u8]) -> Result<(), Error> {
    let lock_path = format!("{dir}/{domain}.ini.lock");
    let tmp_path = format!("{dir}/{domain}.ini.tmp");
    let final_path = format!("{dir}/{domain}.ini");

    let lock = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o644)
        .open(&lock_path)
        .map_err(|e| io_error(format!("open {lock_path}"), &e))?;
    lock.lock().map_err(|e| io_error("flock".into(), &e))?;
    let result = write_and_rename(dir, &tmp_path, &final_path, bytes);
    let _ = lock.unlock();
    result
}

fn write_and_rename(dir: &str, tmp_path: &str, final_path: &str, bytes: &[u8]) -> Result<(), Error> {
    let mut tmp = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o644)
        .open(tmp_path)
        .map_err(|e| io_error(format!("open {tmp_path}"), &e))?;
    let committed = (|| {
        tmp.write_all(bytes).map_err(|e| io_error(format!("write {tmp_path}"), &e))?;
        tmp.sync_all().map_err(|e| io_error("fsync".into(), &e))?;
        drop(tmp);
        std::fs::rename(tmp_path, final_path).map_err(|e| io_error(format!("rename {tmp_path} -> {final_path}"), &e))?;
        if let Ok(d) = File::open(dir) {
            let _ = d.sync_all();
        }
        Ok(())
    })();
    if committed.is_err() {
        let _ = std::fs::remove_file(tmp_path);
    }
    committed
}

/// mkdir -p, each component 0700, tolerating ones that already exist (as
/// anything: a file in the way is found later, as in Swift).
pub(crate) fn make_dirs(path: &str) -> Result<(), Error> {
    let mut partial = String::new();
    for component in path.split('/').filter(|c| !c.is_empty()) {
        partial.push('/');
        partial.push_str(component);
        let p = if path.starts_with('/') { &partial[..] } else { &partial[1..] };
        if let Err(e) = DirBuilder::new().mode(0o700).create(p) {
            if e.kind() != ErrorKind::AlreadyExists {
                return Err(io_error(format!("mkdir {p}"), &e));
            }
        }
    }
    Ok(())
}

/// `<what>: <strerror>`, as Swift words it (without Rust's "(os error N)").
pub(crate) fn io_error(what: String, e: &io::Error) -> Error {
    Error::Io(format!("{what}: {}", strerror(e)))
}

pub(crate) fn strerror(e: &io::Error) -> String {
    let s = e.to_string();
    match s.rfind(" (os error ") {
        Some(i) if s.ends_with(')') => s[..i].to_owned(),
        _ => s,
    }
}

/// Hot reload: wakes when a file in the config directory changes, so a
/// component reloads its config without polling (inotify on Linux, kqueue on
/// FreeBSD, which watches each file too, so an edit in place wakes it).
/// The descriptor is pollable: add it to the component's own loop next to
/// the Wayland fd, and `drain` once that loop reports it ready.
#[derive(Debug)]
pub struct Watcher {
    watch: DirWatch,
}

impl Watcher {
    /// Watch `dir` (default: the config directory).
    pub fn new(dir: Option<&str>) -> Result<Watcher, Error> {
        let d = resolve(dir)?;
        let watch = DirWatch::open(&d).map_err(|_| Error::Io(format!("watch open {d}")))?;
        Ok(Watcher { watch })
    }

    /// Block up to `timeout_ms` (negative = forever) for a change: true if
    /// the directory changed (events drained), false on a timeout.
    pub fn wait(&self, timeout_ms: i32) -> Result<bool, Error> {
        self.watch.wait(timeout_ms).map_err(|_| Error::Io("watch wait".into()))
    }

    /// Non-blocking: drain, and say whether anything changed since the last
    /// look.
    pub fn drain(&self) -> bool {
        self.watch.wait(0).unwrap_or(false)
    }
}

impl AsFd for Watcher {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.watch.as_fd()
    }
}

impl AsRawFd for Watcher {
    fn as_raw_fd(&self) -> RawFd {
        self.watch.as_raw_fd()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_config_dir_precedence() {
        assert_eq!(choose_config_dir(Some("/a"), Some("/x"), Some("/h")).as_deref(), Some("/a"));
        assert_eq!(choose_config_dir(None, Some("/x"), Some("/h")).as_deref(), Some("/x/abyss"));
        assert_eq!(choose_config_dir(None, None, Some("/h")).as_deref(), Some("/h/.config/abyss"));
        assert_eq!(choose_config_dir(None, None, None), None);
        // Set but empty still counts, as getenv sees it.
        assert_eq!(choose_config_dir(Some(""), Some("/x"), None).as_deref(), Some(""));
        assert_eq!(choose_config_dir(None, Some(""), None).as_deref(), Some("/abyss"));
    }

    #[test]
    fn strerror_drops_rusts_suffix() {
        let e = io::Error::from_raw_os_error(libc_enoent());
        assert_eq!(strerror(&e), "No such file or directory");
    }

    fn libc_enoent() -> i32 {
        2
    }
}
