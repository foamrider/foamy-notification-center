// foamy-kit 0.5.1 b5f018d5c973f1115da2ae6c35c7eb8700e6cc24d97cb7b917a04ca05560d45c — do not edit; change foamy-kit and run sync
//! `flock(2)` locks on lock files, including the per-plugin runtime
//! directory `$XDG_RUNTIME_DIR/<plugin>`.
//!
//! A lock is held as long as its [`FileLock`] lives and released when it is
//! dropped or the process dies (the kernel drops `flock` locks with the
//! last descriptor), so a crashed helper never leaves a stale lock.

use std::ffi::OsString;
use std::fs::File;
use std::io::{self, ErrorKind};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use rustix::fs::{self as rfs, FileType, FlockOperation, Mode, OFlags};
use rustix::io::Errno;
use rustix::process::geteuid;

/// A held exclusive lock.
#[derive(Debug)]
pub struct FileLock {
    _file: File,
    path: PathBuf,
}

fn open_lock_file(path: &Path) -> io::Result<File> {
    let flags = OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NOCTTY;
    let fd = rfs::open(path, flags, Mode::from_raw_mode(0o600)).map_err(|error| {
        let error = io::Error::from(error);
        io::Error::new(
            error.kind(),
            format!("cannot open lock file {}: {error}", path.display()),
        )
    })?;
    let stat = rfs::fstat(&fd)?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            format!("{} is not a regular file", path.display()),
        ));
    }
    if stat.st_uid != geteuid().as_raw() {
        return Err(io::Error::new(
            ErrorKind::PermissionDenied,
            format!("{} is not owned by the current user", path.display()),
        ));
    }
    Ok(File::from(fd))
}

impl FileLock {
    /// Takes the lock without waiting: `Ok(None)` when another process (or
    /// another open of the same file) holds it. The lock file is created
    /// with mode 0600; a symlink, a non-regular file or someone else's file
    /// is refused.
    pub fn try_exclusive(path: &Path) -> io::Result<Option<FileLock>> {
        let file = open_lock_file(path)?;
        match rfs::flock(&file, FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => Ok(Some(FileLock {
                _file: file,
                path: path.to_owned(),
            })),
            Err(Errno::WOULDBLOCK) => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    /// Waits for the lock as long as it takes.
    pub fn exclusive(path: &Path) -> io::Result<FileLock> {
        let file = open_lock_file(path)?;
        loop {
            match rfs::flock(&file, FlockOperation::LockExclusive) {
                Ok(()) => {
                    return Ok(FileLock {
                        _file: file,
                        path: path.to_owned(),
                    });
                }
                Err(Errno::INTR) => continue,
                Err(error) => return Err(error.into()),
            }
        }
    }

    /// Waits at most `timeout` for the lock (polling every 10 ms):
    /// `Ok(None)` when it is still held by then.
    pub fn exclusive_within(path: &Path, timeout: Duration) -> io::Result<Option<FileLock>> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(lock) = FileLock::try_exclusive(path)? {
                return Ok(Some(lock));
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            thread::sleep((deadline - now).min(Duration::from_millis(10)));
        }
    }

    /// The lock file.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

fn check_component(kind: &str, name: &str) -> io::Result<()> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            format!("invalid {kind} name {name:?}"),
        ));
    }
    Ok(())
}

fn runtime_dir_in(base: Option<OsString>, plugin: &str) -> io::Result<PathBuf> {
    check_component("plugin", plugin)?;
    let base = base
        .filter(|base| !base.is_empty())
        .ok_or_else(|| io::Error::new(ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))?;
    let base = PathBuf::from(base);
    if !base.is_absolute() {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "XDG_RUNTIME_DIR is not an absolute path",
        ));
    }
    if !base.is_dir() {
        return Err(io::Error::new(
            ErrorKind::NotFound,
            format!("XDG_RUNTIME_DIR {} is not a directory", base.display()),
        ));
    }
    let dir = base.join(plugin);
    crate::fs::ensure_private_dir(&dir)?;
    Ok(dir)
}

/// `$XDG_RUNTIME_DIR/<plugin>` (e.g. `foamy-power`), created with mode 0700
/// and checked like [`crate::fs::ensure_private_dir`]. `NotFound` when
/// `XDG_RUNTIME_DIR` is unset or not a directory, so a caller can fall back.
pub fn runtime_dir(plugin: &str) -> io::Result<PathBuf> {
    runtime_dir_in(std::env::var_os("XDG_RUNTIME_DIR"), plugin)
}

/// [`FileLock::try_exclusive`] on `$XDG_RUNTIME_DIR/<plugin>/<name>.lock`.
pub fn try_runtime_lock(plugin: &str, name: &str) -> io::Result<Option<FileLock>> {
    check_component("lock", name)?;
    FileLock::try_exclusive(&runtime_dir(plugin)?.join(format!("{name}.lock")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs::tests::TempDir;
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn second_holder_is_refused_until_the_first_drops() {
        let dir = TempDir::new("lock");
        let path = dir.0.join("action.lock");
        let first = FileLock::try_exclusive(&path).unwrap().expect("free lock");
        assert_eq!(first.path(), path);
        assert!(FileLock::try_exclusive(&path).unwrap().is_none());
        drop(first);
        assert!(FileLock::try_exclusive(&path).unwrap().is_some());
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn waiting_gives_up_at_the_deadline() {
        let dir = TempDir::new("lock-wait");
        let path = dir.0.join("busy.lock");
        let _held = FileLock::exclusive(&path).unwrap();
        let start = Instant::now();
        assert!(
            FileLock::exclusive_within(&path, Duration::from_millis(60))
                .unwrap()
                .is_none()
        );
        let waited = start.elapsed();
        assert!(
            waited >= Duration::from_millis(60) && waited < Duration::from_secs(2),
            "{waited:?}"
        );
    }

    #[test]
    fn waiting_gets_the_lock_once_released() {
        let dir = TempDir::new("lock-release");
        let path = dir.0.join("busy.lock");
        let held = FileLock::exclusive(&path).unwrap();
        let releaser = thread::spawn(move || {
            thread::sleep(Duration::from_millis(30));
            drop(held);
        });
        assert!(
            FileLock::exclusive_within(&path, Duration::from_secs(5))
                .unwrap()
                .is_some()
        );
        releaser.join().unwrap();
    }

    #[test]
    fn lock_files_must_be_plain_files() {
        let dir = TempDir::new("lock-link");
        let target = dir.0.join("target");
        fs::write(&target, b"").unwrap();
        let link = dir.0.join("link.lock");
        symlink(&target, &link).unwrap();
        assert!(FileLock::try_exclusive(&link).is_err());
        assert!(FileLock::try_exclusive(&dir.0).is_err());
    }

    #[test]
    fn runtime_dirs_are_private_and_validated() {
        let dir = TempDir::new("runtime");
        let base = Some(dir.0.clone().into_os_string());
        let runtime = runtime_dir_in(base.clone(), "foamy-test").unwrap();
        assert_eq!(runtime, dir.0.join("foamy-test"));
        assert_eq!(
            fs::metadata(&runtime).unwrap().permissions().mode() & 0o777,
            0o700
        );
        for bad in ["", ".", "..", "a/b"] {
            assert_eq!(
                runtime_dir_in(base.clone(), bad).unwrap_err().kind(),
                ErrorKind::InvalidInput,
                "{bad:?}"
            );
        }
        assert_eq!(
            runtime_dir_in(None, "foamy-test").unwrap_err().kind(),
            ErrorKind::NotFound
        );
        assert_eq!(
            runtime_dir_in(Some("".into()), "foamy-test")
                .unwrap_err()
                .kind(),
            ErrorKind::NotFound
        );
        assert_eq!(
            runtime_dir_in(Some("relative".into()), "foamy-test")
                .unwrap_err()
                .kind(),
            ErrorKind::InvalidInput
        );
        assert_eq!(
            runtime_dir_in(Some(dir.0.join("missing").into()), "x")
                .unwrap_err()
                .kind(),
            ErrorKind::NotFound
        );
        assert!(check_component("lock", "a/b").is_err());
    }
}
