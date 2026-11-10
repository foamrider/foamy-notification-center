// foamy-kit 0.7.0 2f17136d803e674f7a0576813750d8406680381102023f4669102bbceadc1555 — do not edit; change foamy-kit and run sync
//! Files: atomic writes with owner and type checks, private directories and
//! bounded reads that refuse symlinks and special files.

use std::ffi::{OsStr, OsString};
use std::fs::{DirBuilder, File};
use std::io::{self, ErrorKind, Write};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use rustix::fs::{self as rfs, AtFlags, FileType, Mode, OFlags};
use rustix::io::Errno;
use rustix::process::{geteuid, getpid};

fn context(error: impl Into<io::Error>, what: &str, path: &Path) -> io::Error {
    let error = error.into();
    io::Error::new(error.kind(), format!("{what} {}: {error}", path.display()))
}

fn refuse(kind: ErrorKind, path: &Path, why: &str) -> io::Error {
    io::Error::new(kind, format!("{} {why}", path.display()))
}

/// Checks that an open directory belongs to this user and is not
/// world-writable without the sticky bit (where anyone could swap the
/// file); group-writable is fine, as with umask 002 (`private`: nobody else
/// may read, write or enter it at all).
fn check_directory(fd: impl AsFd, path: &Path, private: bool) -> io::Result<()> {
    let stat = rfs::fstat(fd)?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::Directory {
        return Err(refuse(ErrorKind::InvalidInput, path, "is not a directory"));
    }
    if stat.st_uid != geteuid().as_raw() {
        return Err(refuse(
            ErrorKind::PermissionDenied,
            path,
            "is not owned by the current user",
        ));
    }
    if private && stat.st_mode & 0o077 != 0 {
        return Err(refuse(
            ErrorKind::PermissionDenied,
            path,
            "is accessible to other users (expected mode 0700)",
        ));
    }
    if !private && stat.st_mode & 0o002 != 0 && stat.st_mode & 0o1000 == 0 {
        return Err(refuse(
            ErrorKind::PermissionDenied,
            path,
            "is writable by all users without the sticky bit",
        ));
    }
    Ok(())
}

fn split(path: &Path) -> io::Result<(&Path, &OsStr)> {
    let name = path
        .file_name()
        .ok_or_else(|| refuse(ErrorKind::InvalidInput, path, "has no file name"))?;
    let parent = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };
    Ok((parent, name))
}

fn create_temp(dir: &OwnedFd, parent: &Path) -> io::Result<(OsString, OwnedFd)> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let pid = getpid().as_raw_nonzero();
    for _ in 0..64 {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let name = OsString::from(format!(".foamy-{pid}-{n}.tmp"));
        let flags =
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        match rfs::openat(dir, name.as_os_str(), flags, Mode::from_raw_mode(0o600)) {
            Ok(fd) => return Ok((name, fd)),
            Err(Errno::EXIST) => continue,
            Err(error) => return Err(context(error, "cannot create a temporary file in", parent)),
        }
    }
    Err(refuse(
        ErrorKind::AlreadyExists,
        parent,
        "has too many leftover temporary files",
    ))
}

/// Replaces `path` with `data` atomically: a temporary file in the same
/// directory (created `O_EXCL | O_NOFOLLOW`, mode 0600), `fchmod` to `mode`
/// (exactly, whatever the umask), `fsync`, `rename` over `path`, `fsync` of
/// the directory. Readers see the old content or the new, never a mix.
///
/// Refuses, before writing anything, when the directory is not owned by
/// this user or is world-writable without the sticky bit (a group-writable
/// directory of the user's own, as with umask 002, is fine), or when `path`
/// exists but is not a regular file owned by this user (a symlink is never
/// followed or replaced). The temporary file is removed on failure.
pub fn write_atomic(path: &Path, data: &[u8], mode: u32) -> io::Result<()> {
    let (parent, name) = split(path)?;
    let dir = rfs::open(
        parent,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| context(error, "cannot open directory", parent))?;
    check_directory(&dir, parent, false)?;
    match rfs::statat(&dir, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(stat) => {
            if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
                return Err(refuse(
                    ErrorKind::InvalidInput,
                    path,
                    "exists and is not a regular file",
                ));
            }
            if stat.st_uid != geteuid().as_raw() {
                return Err(refuse(
                    ErrorKind::PermissionDenied,
                    path,
                    "is not owned by the current user",
                ));
            }
        }
        Err(Errno::NOENT) => {}
        Err(error) => return Err(context(error, "cannot inspect", path)),
    }
    let (temp, fd) = create_temp(&dir, parent)?;
    let written = (|| -> io::Result<()> {
        rfs::fchmod(&fd, Mode::from_raw_mode(mode & 0o7777))?;
        let mut file = File::from(fd);
        file.write_all(data)?;
        file.sync_all()?;
        rfs::renameat(&dir, temp.as_os_str(), &dir, name)?;
        Ok(())
    })();
    if let Err(error) = written {
        let _ = rfs::unlinkat(&dir, temp.as_os_str(), AtFlags::empty());
        return Err(context(error, "cannot write", path));
    }
    rfs::fsync(&dir).map_err(|error| context(error, "cannot sync directory", parent))
}

/// Creates `path` (and missing parents) with mode 0700, then checks that
/// `path` is a directory, not a symlink, owned by this user and closed to
/// everyone else. An existing directory with a wider mode is an error, not
/// silently tightened.
pub fn ensure_private_dir(path: &Path) -> io::Result<()> {
    match DirBuilder::new().recursive(true).mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
        Err(error) => return Err(context(error, "cannot create directory", path)),
    }
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let fd = rfs::open(path, flags, Mode::empty()).map_err(|error| match error {
        Errno::LOOP | Errno::NOTDIR => refuse(
            ErrorKind::InvalidInput,
            path,
            "is a symlink or not a directory",
        ),
        error => context(error, "cannot open directory", path),
    })?;
    check_directory(&fd, path, true)
}

/// Reads a regular file of at most `limit` bytes. Symlinks (as the last path
/// component), FIFOs, devices and directories are refused, so a hostile path
/// can neither redirect the read nor block it.
pub fn read_file_limited(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let flags =
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY;
    let fd = rfs::open(path, flags, Mode::empty()).map_err(|error| match error {
        Errno::LOOP => refuse(ErrorKind::InvalidInput, path, "is a symlink"),
        error => context(error, "cannot open", path),
    })?;
    let stat = rfs::fstat(&fd)?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err(refuse(
            ErrorKind::InvalidInput,
            path,
            "is not a regular file",
        ));
    }
    crate::io::read_limited(File::from(fd), limit)
        .map_err(|error| context(error, "cannot read", path))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::PathBuf;

    /// A private temporary directory, removed on drop.
    pub(crate) struct TempDir(pub PathBuf);

    impl TempDir {
        pub(crate) fn new(tag: &str) -> TempDir {
            static N: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "foamy-helper-{tag}-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            DirBuilder::new().mode(0o700).create(&path).unwrap();
            TempDir(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o700));
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn mode(path: &Path) -> u32 {
        fs::symlink_metadata(path).unwrap().permissions().mode() & 0o7777
    }

    fn entries(dir: &Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn writes_new_and_replaces_existing_files() {
        let dir = TempDir::new("write");
        let target = dir.0.join("state");
        write_atomic(&target, b"one\n", 0o600).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"one\n");
        assert_eq!(mode(&target), 0o600);
        write_atomic(&target, b"two\n", 0o644).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"two\n");
        assert_eq!(
            mode(&target),
            0o644,
            "mode is exact, not filtered by the umask"
        );
        assert_eq!(
            entries(&dir.0),
            ["state"],
            "no temporary file is left behind"
        );
    }

    #[test]
    fn never_follows_or_replaces_a_symlink() {
        let dir = TempDir::new("symlink");
        let real = dir.0.join("real");
        fs::write(&real, b"keep").unwrap();
        let link = dir.0.join("link");
        symlink(&real, &link).unwrap();
        let error = write_atomic(&link, b"evil", 0o600).unwrap_err();
        assert!(error.to_string().contains("not a regular file"), "{error}");
        assert_eq!(fs::read(&real).unwrap(), b"keep");
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(entries(&dir.0), ["link", "real"]);
    }

    #[test]
    fn refuses_directories_and_shared_parents() {
        let dir = TempDir::new("refuse");
        fs::create_dir(dir.0.join("sub")).unwrap();
        assert!(write_atomic(&dir.0.join("sub"), b"x", 0o600).is_err());
        fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o777)).unwrap();
        let error = write_atomic(&dir.0.join("file"), b"x", 0o600).unwrap_err();
        assert!(
            error.to_string().contains("writable by all users"),
            "{error}"
        );
        assert!(!dir.0.join("file").exists());
        // Foreign-owned (root's /), even with the sticky bit (/tmp).
        assert!(write_atomic(Path::new("/"), b"x", 0o600).is_err());
        let tmp = write_atomic(Path::new("/tmp/foamy-helper-never"), b"x", 0o600).unwrap_err();
        assert!(tmp.to_string().contains("not owned"), "{tmp}");
    }

    #[test]
    fn accepts_group_writable_and_sticky_own_directories() {
        let dir = TempDir::new("umask002");
        for mode in [0o775, 0o770, 0o1777] {
            fs::set_permissions(&dir.0, fs::Permissions::from_mode(mode)).unwrap();
            write_atomic(&dir.0.join("state"), format!("{mode:o}").as_bytes(), 0o600).unwrap();
            assert_eq!(
                fs::read_to_string(dir.0.join("state")).unwrap(),
                format!("{mode:o}")
            );
        }
        // ensure_private_dir stays strict.
        fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o770)).unwrap();
        assert!(ensure_private_dir(&dir.0).is_err());
    }

    #[test]
    fn private_dirs_are_created_and_checked() {
        let dir = TempDir::new("private");
        let runtime = dir.0.join("a/b");
        ensure_private_dir(&runtime).unwrap();
        assert_eq!(mode(&runtime), 0o700);
        ensure_private_dir(&runtime).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            ensure_private_dir(&runtime)
                .unwrap_err()
                .to_string()
                .contains("other users")
        );
        let link = dir.0.join("link");
        symlink(&runtime, &link).unwrap();
        assert!(
            ensure_private_dir(&link)
                .unwrap_err()
                .to_string()
                .contains("symlink")
        );
        fs::write(dir.0.join("file"), b"").unwrap();
        assert!(ensure_private_dir(&dir.0.join("file")).is_err());
    }

    #[test]
    fn bounded_file_reads_refuse_links_and_special_files() {
        let dir = TempDir::new("read");
        let file = dir.0.join("file");
        fs::write(&file, b"12345").unwrap();
        assert_eq!(read_file_limited(&file, 5).unwrap(), b"12345");
        assert!(crate::io::is_over_limit(&io::Error::other(
            crate::io::TooLarge { limit: 1 }
        )));
        assert!(
            read_file_limited(&file, 4)
                .unwrap_err()
                .to_string()
                .contains("larger than 4 bytes")
        );
        let link = dir.0.join("link");
        symlink(&file, &link).unwrap();
        assert!(
            read_file_limited(&link, 64)
                .unwrap_err()
                .to_string()
                .contains("symlink")
        );
        assert!(
            read_file_limited(&dir.0, 64)
                .unwrap_err()
                .to_string()
                .contains("not a regular file")
        );
        assert!(
            read_file_limited(Path::new("/dev/null"), 64)
                .unwrap_err()
                .to_string()
                .contains("not a regular file")
        );
    }
}
