// foamy-kit 0.5.0 45275bb9a332e9ce9aafab9c1df2e9bb388cb0954dea4086bd17016e285d035e — do not edit; change foamy-kit and run sync
//! Website favicons from the local caches of Chromium-family browsers,
//! **without any web request** (cargo feature `favicon`). A port of
//! foamy-notifications' and foamy-notification-center's
//! `bin/browser-favicon.py`, with the same contract:
//!
//! - stdin: one JSON object of at most 4096 bytes,
//!   `{"browser": "vivaldi", "hostname": "teams.microsoft.com"}`;
//! - stdout: one line `{"source": "file:///…/<sha256>.png", "status": "found"}`
//!   (also `"cached"`), `{"source": "", "status": "not-found"}`,
//!   `"cache-unavailable"` (a cache exists but couldn't be read safely),
//!   `"unsupported-browser"`, or `"error"` with exit 1 (and
//!   `Favicon lookup failed: <kind>` on stderr) for a bad request;
//! - the icon is copied to `$XDG_CACHE_HOME/foamy/browser-favicons/`
//!   (mode 0600, umask 077, at most 256 files, reused for 24 hours).
//!
//! The lookup reads `Favicons` under `<config>/<browser root>`, `Default/`
//! and at most fifteen `Profile *` directories, with a 2 s deadline. Each
//! database is read like a read-only SQLite connection would read it (a
//! `SHARED` lock, 100 ms busy timeout). A database the browser holds
//! exclusively is copied into memory instead (at most 32 MiB, refused with
//! transaction sidecars, refused when it changes while being copied, checked
//! structurally) and never written to disk. Only PNGs of 1–256 px and
//! 24 B–64 KiB are accepted, for `https://<host>/…` first, then `http://`.
//!
//! SQLite is read by a small built-in reader (`favicon/sqlite.rs`), not the
//! C library: see the kit CHANGELOG (0.5.0) for why.
//!
//! A plugin helper runs the whole contract with [`run`]; [`resolve`],
//! [`lookup`], [`valid_png`] and [`valid_hostname`] are the parts.

mod sqlite;

use std::ffi::OsString;
use std::fs::{self, DirBuilder};
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::json::Failure;
use sqlite::{Database, Fault, FileState, Key, Record, broken, sidecar, state_of};

/// Largest request on standard input.
pub const MAX_REQUEST_BYTES: u64 = 4096;
/// Largest icon accepted (and read from a cache file).
pub const MAX_ICON_BYTES: usize = 65536;
/// Largest database copied into memory when the browser holds it locked.
pub const MAX_DATABASE_BYTES: u64 = 32 * 1024 * 1024;
/// Deadline of one lookup across all databases.
pub const LOOKUP_TIMEOUT: Duration = Duration::from_secs(2);
/// A cached icon younger than this is returned without a lookup.
pub const CACHE_MAX_AGE: Duration = Duration::from_secs(86400);
/// Icons kept in the cache directory (newest first).
pub const CACHE_ENTRIES: usize = 256;

const EDGE: &[&str] = &[
    "microsoft-edge",
    "microsoft-edge-beta",
    "microsoft-edge-dev",
];
const CHROME: &[&str] = &[
    "google-chrome",
    "google-chrome-beta",
    "google-chrome-unstable",
];
const ROOTS: &[(&str, &[&str])] = &[
    ("vivaldi", &["vivaldi", "vivaldi-snapshot"]),
    ("brave", &["BraveSoftware/Brave-Browser"]),
    ("microsoft-edge", EDGE),
    ("msedge", EDGE),
    ("chromium", &["chromium"]),
    ("google-chrome", CHROME),
    ("chrome", CHROME),
    ("opera", &["opera", "opera-developer"]),
];

/// The config directories (below `$XDG_CONFIG_HOME`) searched for
/// `browser`, or `None` for a browser the lookup doesn't support.
pub fn browser_roots(browser: &str) -> Option<&'static [&'static str]> {
    ROOTS
        .iter()
        .find(|(name, _)| *name == browser)
        .map(|(_, roots)| *roots)
}

/// A lowercase DNS name of at least two labels (the last starting with a
/// letter), each 1–63 characters of `a-z0-9-` not starting or ending with
/// `-`, at most 253 characters in all: the Python helper's `HOST` pattern.
/// No port, scheme, path, IP literal or trailing dot.
pub fn valid_hostname(host: &str) -> bool {
    if host.is_empty() || host.len() > 253 {
        return false;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 {
        return false;
    }
    let label_ok = |label: &str| {
        let bytes = label.as_bytes();
        (1..=63).contains(&bytes.len())
            && bytes
                .iter()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
            && bytes[0] != b'-'
            && bytes[bytes.len() - 1] != b'-'
    };
    labels.iter().all(|label| label_ok(label))
        && labels[labels.len() - 1].as_bytes()[0].is_ascii_lowercase()
}

/// A PNG of 24 B–64 KiB whose `IHDR` says 1–256 px in both directions.
pub fn valid_png(data: &[u8]) -> bool {
    if !(24..=MAX_ICON_BYTES).contains(&data.len()) {
        return false;
    }
    if &data[..8] != b"\x89PNG\r\n\x1a\n" || &data[12..16] != b"IHDR" {
        return false;
    }
    let width = u32::from_be_bytes(data[16..20].try_into().expect("four bytes"));
    let height = u32::from_be_bytes(data[20..24].try_into().expect("four bytes"));
    (1..=256).contains(&width) && (1..=256).contains(&height)
}

/// The result of [`lookup`]: the icon (empty when none was found), and
/// whether some cache could not be read (`"cache-unavailable"` rather than
/// `"not-found"`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Lookup {
    /// The PNG, or empty.
    pub data: Vec<u8>,
    /// A database existed but was locked, corrupt, in a transaction or too
    /// slow to read.
    pub unavailable: bool,
}

/// Finds a favicon for `host` in `browser`'s caches below `config`
/// (`$XDG_CONFIG_HOME`), within [`LOOKUP_TIMEOUT`]. Never writes anything.
pub fn lookup(browser: &str, host: &str, config: &Path) -> Lookup {
    lookup_until(browser, host, config, Instant::now() + LOOKUP_TIMEOUT)
}

fn profiles(root: &Path) -> Vec<PathBuf> {
    // `root.glob('Profile */Favicons')`: directories (symlinks followed)
    // named "Profile …" that contain an entry named Favicons, sorted.
    let mut found: Vec<PathBuf> = fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.file_name().as_bytes().starts_with(b"Profile "))
        .filter(|entry| fs::metadata(entry.path()).is_ok_and(|meta| meta.is_dir()))
        .map(|entry| entry.path().join("Favicons"))
        .filter(|path| fs::symlink_metadata(path).is_ok())
        .collect();
    found.sort_by(|a, b| a.as_os_str().as_bytes().cmp(b.as_os_str().as_bytes()));
    found.truncate(15);
    found
}

fn lookup_until(browser: &str, host: &str, config: &Path, deadline: Instant) -> Lookup {
    let mut unavailable = false;
    for name in browser_roots(browser).unwrap_or_default() {
        let root = config.join(name);
        // Fixed browser roots and at most sixteen ordinary profiles.
        let mut databases = vec![root.join("Favicons"), root.join("Default/Favicons")];
        if root.is_dir() {
            databases.extend(profiles(&root));
        }
        for database in databases {
            if Instant::now() >= deadline {
                return Lookup {
                    data: Vec::new(),
                    unavailable: true,
                };
            }
            if !database.is_file() || database.is_symlink() {
                continue;
            }
            let found = match live_favicon(&database, host, deadline) {
                Ok(data) => data,
                Err(Fault::Busy) => match locked_favicon(&database, host, deadline) {
                    Ok(data) => data,
                    Err(_) => {
                        unavailable = true;
                        continue;
                    }
                },
                Err(Fault::Broken(_)) => {
                    unavailable = true;
                    continue;
                }
            };
            if !found.is_empty() {
                return Lookup {
                    data: found,
                    unavailable,
                };
            }
        }
    }
    Lookup {
        data: Vec::new(),
        unavailable,
    }
}

/// Reads the live database under SQLite's `SHARED` lock. A WAL reader holds
/// no WAL lock here, so a read during which the files changed is retried
/// once and then given up.
fn live_favicon(path: &Path, host: &str, deadline: Instant) -> sqlite::Result<Vec<u8>> {
    for _ in 0..2 {
        let db = Database::open_live(path, deadline)?;
        let result = query(&db, host, deadline);
        if db.unchanged() {
            return result;
        }
    }
    broken("cache changed during reading")
}

fn file_state(path: &Path) -> sqlite::Result<Option<FileState>> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
        Ok(meta) if !meta.file_type().is_file() => broken("non-regular cache file"),
        Ok(meta) => Ok(Some(state_of(&meta))),
    }
}

/// The database and its `-journal`, `-wal` and `-shm` sidecars, checked:
/// the database exists, is 1 B–32 MiB, and no transaction is in progress
/// (no non-empty journal, no WAL or shared-memory file).
fn snapshot_state(path: &Path) -> sqlite::Result<[Option<FileState>; 4]> {
    let state = [
        file_state(path)?,
        file_state(&sidecar(path, "-journal"))?,
        file_state(&sidecar(path, "-wal"))?,
        file_state(&sidecar(path, "-shm"))?,
    ];
    match state[0] {
        Some((_, _, size, _, _)) if size > 0 && size <= MAX_DATABASE_BYTES => {}
        _ => return broken("cache exceeds the copy limit"),
    }
    // Never guess at a live transaction or reconstruct a WAL outside SQLite.
    if state[1].is_some_and(|(_, _, size, _, _)| size > 0) || state[2..].iter().any(Option::is_some)
    {
        return broken("cache has transaction sidecars");
    }
    Ok(state)
}

/// Copies a locked database into memory: twice at most, each time checking
/// that nothing (size, inode, times, sidecars) changed between the first
/// look and the end of the copy, and that it is a rollback-journal database.
fn copy_snapshot(path: &Path, deadline: Instant) -> sqlite::Result<Vec<u8>> {
    copy_snapshot_with(path, deadline, &mut snapshot_state)
}

fn copy_snapshot_with(
    path: &Path,
    deadline: Instant,
    state: &mut dyn FnMut(&Path) -> sqlite::Result<[Option<FileState>; 4]>,
) -> sqlite::Result<Vec<u8>> {
    use rustix::fs::{Mode, OFlags};
    for _ in 0..2 {
        if Instant::now() >= deadline {
            return broken("copy deadline exceeded");
        }
        let before = state(path)?;
        // Browser data stays in memory, so even a killed helper leaves no copy.
        let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC;
        let mut source = fs::File::from(rustix::fs::open(path, flags, Mode::empty())?);
        let opened = source.metadata()?;
        if !opened.file_type().is_file() || Some(state_of(&opened)) != before[0] {
            continue;
        }
        let mut remaining = opened.size();
        let mut image = Vec::with_capacity(remaining as usize);
        let mut chunk = vec![0u8; 256 * 1024];
        while remaining > 0 {
            if Instant::now() >= deadline {
                return broken("copy deadline exceeded");
            }
            let want = remaining.min(chunk.len() as u64) as usize;
            let n = source.read(&mut chunk[..want])?;
            if n == 0 {
                break;
            }
            image.extend_from_slice(&chunk[..n]);
            remaining -= n as u64;
        }
        if remaining > 0 || state(path)? != before {
            continue;
        }
        if image.len() < 20 || &image[..16] != b"SQLite format 3\0" || image[18..20] != [1, 1] {
            return broken("cache is not a rollback database");
        }
        return Ok(image);
    }
    broken("cache changed during copying")
}

/// The fallback for a database the browser holds locked: only the
/// in-memory copy is inspected, after a structural check.
fn locked_favicon(path: &Path, host: &str, deadline: Instant) -> sqlite::Result<Vec<u8>> {
    let image = copy_snapshot(path, deadline)?;
    favicon_in_image(image, host, deadline)
}

fn favicon_in_image(image: Vec<u8>, host: &str, deadline: Instant) -> sqlite::Result<Vec<u8>> {
    let db = Database::from_image(image, deadline)?;
    db.check()?;
    query(&db, host, deadline)
}

struct Table {
    root: u32,
    columns: Vec<sqlite::Column>,
}

impl Table {
    fn open(db: &Database, name: &str) -> sqlite::Result<Table> {
        let Some((root, sql)) = db.table(name)? else {
            return broken(format!("no such table: {name}"));
        };
        if root == 0 {
            return broken(format!("{name} is not an ordinary table"));
        }
        Ok(Table {
            root,
            columns: sqlite::columns(&sql)?,
        })
    }

    fn column(&self, name: &str) -> sqlite::Result<usize> {
        self.columns
            .iter()
            .position(|column| column.name.eq_ignore_ascii_case(name))
            .map_or_else(|| broken(format!("no such column: {name}")), Ok)
    }

    /// Column `index` of `record` (for text and blobs at most `limit`
    /// bytes): the rowid for an `INTEGER PRIMARY KEY`, the default for a
    /// column the row predates.
    fn get(
        &self,
        record: &Record<'_>,
        index: usize,
        limit: usize,
    ) -> sqlite::Result<sqlite::Value> {
        let column = &self.columns[index];
        if column.rowid {
            Ok(sqlite::Value::Int(record.rowid))
        } else if index < record.len() {
            record.value(index, limit)
        } else {
            Ok(column.default.clone())
        }
    }
}

/// `length()` of a text value: characters up to the first NUL (SQLite
/// counts UTF-8 lead bytes).
fn text_length(bytes: &[u8]) -> usize {
    bytes
        .iter()
        .take_while(|&&b| b != 0)
        .filter(|&&b| b & 0xc0 != 0x80)
        .count()
}

/// One row of the join, ordered like `ORDER BY abs(b.width - 32),
/// b.last_updated DESC` (ties in scan order).
struct Candidate<'a> {
    distance: f64,
    updated: sqlite::Value,
    order: usize,
    record: std::rc::Rc<Record<'a>>,
}

/// The Python helper's query, per scheme (`https://` first):
///
/// ```sql
/// SELECT b.image_data FROM icon_mapping m
/// JOIN favicon_bitmaps b ON m.icon_id = b.icon_id
/// WHERE m.page_url >= '<scheme><host>/' AND m.page_url < '<scheme><host>0'
///   AND b.width BETWEEN 1 AND 256 AND b.height BETWEEN 1 AND 256
///   AND length(b.image_data) BETWEEN 24 AND 65536
/// ORDER BY abs(b.width - 32), b.last_updated DESC LIMIT 8
/// ```
///
/// and the first of those rows that is a [`valid_png`].
fn query(db: &Database, host: &str, deadline: Instant) -> sqlite::Result<Vec<u8>> {
    if Instant::now() >= deadline {
        return broken("lookup deadline exceeded");
    }
    let mapping = Table::open(db, "icon_mapping")?;
    let bitmaps = Table::open(db, "favicon_bitmaps")?;
    let (page_url, mapped_icon) = (mapping.column("page_url")?, mapping.column("icon_id")?);
    let icon = bitmaps.column("icon_id")?;
    let image = bitmaps.column("image_data")?;
    let (width, height) = (bitmaps.column("width")?, bitmaps.column("height")?);
    let updated = bitmaps.column("last_updated")?;

    // `page_url >= p AND page_url < q` where q is p with its final '/'
    // replaced by '0' (the next byte) is exactly "page_url starts with p",
    // for text compared bytewise; other storage classes never match.
    let prefixes = [format!("https://{host}/"), format!("http://{host}/")];
    let longest = prefixes.iter().map(String::len).max().unwrap_or(0);
    let mut wanted: [std::collections::HashMap<Key, usize>; 2] = Default::default();
    db.scan(mapping.root, &mut |record| {
        let sqlite::Value::Text(url) = mapping.get(&record, page_url, longest)? else {
            return Ok(());
        };
        for (scheme, prefix) in prefixes.iter().enumerate() {
            if url.starts_with(prefix.as_bytes())
                && let Some(key) = mapping.get(&record, mapped_icon, 4096)?.join_key()
            {
                *wanted[scheme].entry(key).or_default() += 1;
            }
        }
        Ok(())
    })?;
    if wanted.iter().all(|matches| matches.is_empty()) {
        return Ok(Vec::new());
    }

    let mut best: [Vec<Candidate<'_>>; 2] = Default::default();
    let mut order = 0usize;
    db.scan(bitmaps.root, &mut |record| {
        let Some(key) = bitmaps.get(&record, icon, 4096)?.join_key() else {
            return Ok(());
        };
        let counts = [wanted[0].get(&key).copied(), wanted[1].get(&key).copied()];
        if counts.iter().all(Option::is_none) {
            return Ok(());
        }
        let in_range = |value: Option<f64>| value.is_some_and(|v| (1.0..=256.0).contains(&v));
        let w = bitmaps.get(&record, width, 0)?.number();
        if !in_range(w) || !in_range(bitmaps.get(&record, height, 0)?.number()) {
            return Ok(());
        }
        let length = if bitmaps.columns[image].rowid || image >= record.len() {
            None // an integer or NULL: never 24+ characters
        } else {
            match record.kind(image) {
                Some((false, true, bytes)) => Some(bytes as usize),
                Some((true, false, bytes)) if bytes >= 24 => {
                    match record.value(image, 4 * MAX_ICON_BYTES + 4)? {
                        sqlite::Value::Text(text) => Some(text_length(&text)),
                        _ => None,
                    }
                }
                _ => None,
            }
        };
        if !length.is_some_and(|n| (24..=MAX_ICON_BYTES).contains(&n)) {
            return Ok(());
        }
        let distance = (w.unwrap_or_default() - 32.0).abs();
        let last = bitmaps.get(&record, updated, 4096)?;
        let record = std::rc::Rc::new(record);
        for (scheme, count) in counts.iter().enumerate() {
            // One join row per matching mapping row.
            for _ in 0..count.unwrap_or(0).min(8) {
                order += 1;
                let list = &mut best[scheme];
                list.push(Candidate {
                    distance,
                    updated: last.clone(),
                    order,
                    record: std::rc::Rc::clone(&record),
                });
                list.sort_by(|a, b| {
                    a.distance
                        .total_cmp(&b.distance)
                        .then_with(|| b.updated.sql_cmp(&a.updated))
                        .then(a.order.cmp(&b.order))
                });
                list.truncate(8);
            }
        }
        Ok(())
    })?;
    for list in &best {
        for candidate in list {
            if let sqlite::Value::Blob(data) = candidate.record.value(image, MAX_ICON_BYTES)?
                && valid_png(&data)
            {
                return Ok(data);
            }
        }
    }
    Ok(Vec::new())
}

/// Where the lookup reads and the icons go.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dirs {
    /// `$XDG_CONFIG_HOME` (default `~/.config`): the browsers' profiles.
    pub config: PathBuf,
    /// `$XDG_CACHE_HOME/foamy/browser-favicons` (default under `~/.cache`).
    pub cache: PathBuf,
}

fn home() -> Result<PathBuf, Failure> {
    let trim = |path: OsString| {
        let bytes = path.as_bytes();
        let end = bytes.iter().rposition(|&b| b != b'/').map_or(0, |i| i + 1);
        if end == 0 {
            PathBuf::from("/")
        } else {
            PathBuf::from(std::ffi::OsStr::from_bytes(&bytes[..end]))
        }
    };
    if let Some(home) = std::env::var_os("HOME") {
        return Ok(trim(home));
    }
    passwd_home()
        .map(trim)
        .ok_or_else(|| Failure::coded("RuntimeError", "could not determine the home directory"))
}

fn passwd_home() -> Option<OsString> {
    let mut entry: libc::passwd = unsafe_zeroed_passwd();
    let mut buffer = vec![0 as libc::c_char; 16384];
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call: `entry` and `result` are
    // locals, `buffer` is a live allocation of the given length.
    let rc = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut entry,
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut result,
        )
    };
    if rc != 0 || result.is_null() || entry.pw_dir.is_null() {
        return None;
    }
    // SAFETY: on success `pw_dir` points to a NUL-terminated string inside
    // `buffer`, which is still alive.
    let dir = unsafe { std::ffi::CStr::from_ptr(entry.pw_dir) };
    Some(std::ffi::OsStr::from_bytes(dir.to_bytes()).to_owned())
}

fn unsafe_zeroed_passwd() -> libc::passwd {
    // SAFETY: `struct passwd` is plain old data (pointers and integers), for
    // which all-zero bytes are a valid value; getpwuid_r fills it in.
    unsafe { std::mem::zeroed() }
}

impl Dirs {
    /// From `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `HOME` (or the passwd
    /// entry), as the Python helper: a variable that is set is used as is,
    /// even when empty or relative.
    pub fn from_env() -> Result<Dirs, Failure> {
        let config = match std::env::var_os("XDG_CONFIG_HOME") {
            Some(dir) => PathBuf::from(dir),
            None => home()?.join(".config"),
        };
        let cache = match std::env::var_os("XDG_CACHE_HOME") {
            Some(dir) => PathBuf::from(dir),
            None => home()?.join(".cache"),
        };
        Ok(Dirs {
            config,
            cache: cache.join("foamy/browser-favicons"),
        })
    }
}

/// What [`resolve`] answers: `source` is a `file://` URI or empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    /// `file://…/<sha256>.png`, or `""`.
    pub source: String,
    /// `found`, `cached`, `not-found`, `cache-unavailable` or
    /// `unsupported-browser` (`error` comes from [`run`]).
    pub status: &'static str,
}

impl Reply {
    fn empty(status: &'static str) -> Reply {
        Reply {
            source: String::new(),
            status,
        }
    }

    /// The reply line exactly as Python's `json.dumps` printed it.
    pub fn to_line(&self) -> String {
        let source = serde_json::to_string(&self.source).expect("strings always encode");
        format!(
            "{{\"source\": {source}, \"status\": \"{}\"}}\n",
            self.status
        )
    }
}

/// `file://` plus the path, percent-encoded except `A-Za-z0-9_.-~/`
/// (Python's `Path.as_uri()`); a relative path has no URI.
fn file_uri(path: &Path) -> Result<String, Failure> {
    if !path.is_absolute() {
        return Err(Failure::coded(
            "ValueError",
            "relative path can't be expressed as a file URI",
        ));
    }
    let mut uri = String::from("file://");
    for &byte in path.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || b"_.-~/".contains(&byte) {
            uri.push(byte as char);
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    Ok(uri)
}

fn os_failure(error: io::Error) -> Failure {
    Failure::coded("OSError", error.to_string())
}

/// A fresh cached icon at `target`: a regular file (not a symlink) younger
/// than [`CACHE_MAX_AGE`] that is a [`valid_png`].
fn cached(target: &Path) -> bool {
    let fresh = fs::symlink_metadata(target).is_ok_and(|meta| {
        let modified = meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        meta.file_type().is_file() && now - modified < CACHE_MAX_AGE.as_secs_f64()
    });
    fresh
        && crate::fs::read_file_limited(target, MAX_ICON_BYTES as u64 + 1)
            .is_ok_and(|data| valid_png(&data))
}

/// Keeps the [`CACHE_ENTRIES`] newest `*.png` files in `cache`.
fn prune(cache: &Path) {
    let mut files: Vec<(f64, PathBuf)> = fs::read_dir(cache)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.file_name().as_bytes().ends_with(b".png"))
        .filter_map(|entry| {
            let meta = fs::metadata(entry.path()).ok()?;
            Some((
                meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9,
                entry.path(),
            ))
        })
        .collect();
    files.sort_by(|a, b| {
        b.0.total_cmp(&a.0)
            .then_with(|| b.1.as_os_str().as_bytes().cmp(a.1.as_os_str().as_bytes()))
    });
    for (_, path) in files.iter().skip(CACHE_ENTRIES) {
        let _ = fs::remove_file(path);
    }
}

/// Answers one request object (`{"browser": …, "hostname": …}`): the cached
/// icon, a fresh lookup copied into the cache, or why there is none. `Err`
/// is the `"error"` reply (invalid hostname, unusable cache directory).
pub fn resolve(request: &Value, dirs: &Dirs) -> Result<Reply, Failure> {
    resolve_with(request, || Ok(dirs.clone()))
}

fn resolve_with(
    request: &Value,
    dirs: impl FnOnce() -> Result<Dirs, Failure>,
) -> Result<Reply, Failure> {
    let browser = request.get("browser");
    if matches!(browser, Some(Value::Array(_) | Value::Object(_))) {
        return Err(Failure::coded("TypeError", "unhashable browser"));
    }
    let Some(browser) = browser
        .and_then(Value::as_str)
        .filter(|b| browser_roots(b).is_some())
    else {
        return Ok(Reply::empty("unsupported-browser"));
    };
    let host = request.get("hostname").and_then(Value::as_str);
    let Some(host) = host.filter(|host| valid_hostname(host)) else {
        return Err(Failure::coded("ValueError", "Invalid website hostname"));
    };
    let dirs = dirs()?;
    let digest = crate::hash::sha256(format!("{browser}\n{host}").as_bytes());
    let name: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let target = dirs.cache.join(format!("{name}.png"));
    if cached(&target) {
        return Ok(Reply {
            source: file_uri(&target)?,
            status: "cached",
        });
    }
    let found = lookup(browser, host, &dirs.config);
    if found.data.is_empty() {
        return Ok(Reply::empty(if found.unavailable {
            "cache-unavailable"
        } else {
            "not-found"
        }));
    }
    match DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dirs.cache)
    {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists && dirs.cache.is_dir() => {}
        Err(error) => return Err(os_failure(error)),
    }
    crate::fs::write_atomic(&target, &found.data, 0o600).map_err(os_failure)?;
    // Bound the shared cache; each plugin falls back if an older displayed
    // file expires.
    prune(&dirs.cache);
    Ok(Reply {
        source: file_uri(&target)?,
        status: "found",
    })
}

fn request_from(raw: &[u8]) -> Result<Value, Failure> {
    let raw = raw.strip_prefix(b"\xef\xbb\xbf").unwrap_or(raw);
    let request: Value = serde_json::from_slice(raw)
        .map_err(|error| Failure::coded("JSONDecodeError", error.to_string()))?;
    if !request.is_object() {
        return Err(Failure::coded(
            "ValueError",
            "Expected a favicon request object",
        ));
    }
    Ok(request)
}

/// The whole helper contract (see the module docs): umask 077, the request
/// from standard input, one reply line on standard output. A panic prints
/// the `"error"` reply and exits 101.
pub fn run() -> ExitCode {
    const ERROR: Reply = Reply {
        source: String::new(),
        status: "error",
    };
    crate::process::exit_on_panic_after(101, || {
        let _ = io::Write::write_all(&mut io::stdout().lock(), ERROR.to_line().as_bytes());
    });
    crate::process::set_umask(0o077);
    let outcome = crate::io::read_stdin_limited(MAX_REQUEST_BYTES)
        .map_err(|error| {
            if crate::io::is_over_limit(&error) {
                Failure::coded("ValueError", "Favicon request exceeds the size limit")
            } else {
                os_failure(error)
            }
        })
        .and_then(|raw| request_from(&raw))
        .and_then(|request| resolve_with(&request, Dirs::from_env));
    let (reply, code) = match outcome {
        Ok(reply) => (reply, ExitCode::SUCCESS),
        Err(failure) => {
            eprintln!("Favicon lookup failed: {}", failure.code);
            (ERROR, ExitCode::FAILURE)
        }
    };
    match io::Write::write_all(&mut io::stdout().lock(), reply.to_line().as_bytes()) {
        Ok(()) => code,
        Err(_) => ExitCode::FAILURE,
    }
}

#[cfg(test)]
mod tests;
