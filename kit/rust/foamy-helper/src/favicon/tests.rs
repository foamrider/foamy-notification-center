// foamy-kit 0.9.0 3b092b6e431e128eda90551c6e517778828ed7b80e3ffcfa9d7cb6a3add54ff6 — do not edit; change foamy-kit and run sync
//! The favicon lookup against real SQLite files. The databases are written
//! (and browsers holding them simulated) with Python's `sqlite3` module, the
//! same library the Python helper used; without `python3` these tests are
//! skipped with a message.

use super::*;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};

use crate::fs::tests::TempDir;

fn python() -> bool {
    let ok = Command::new("python3")
        .args(["-c", "import sqlite3"])
        .status()
        .is_ok_and(|s| s.success());
    if !ok {
        eprintln!("SKIP favicon database tests: python3 with sqlite3 not found");
    }
    ok
}

fn hex(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
}

/// A PNG header the lookup accepts (`size` px square, padded to `len`).
fn png(size: u32, len: usize) -> Vec<u8> {
    let mut data = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    data.extend_from_slice(&size.to_be_bytes());
    data.extend_from_slice(&size.to_be_bytes());
    data.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);
    data.resize(len.max(data.len()), 0x42);
    data
}

const TEST_SCHEMA: &str = "CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER); \
    CREATE INDEX urls ON icon_mapping(page_url); \
    CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER, height INTEGER, last_updated INTEGER);";

const CHROMIUM_SCHEMA: &str = "CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY,page_url LONGVARCHAR NOT NULL,icon_id INTEGER); \
    CREATE INDEX icon_mapping_page_url_idx ON icon_mapping(page_url); \
    CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY,icon_id INTEGER NOT NULL,last_updated INTEGER DEFAULT 0,image_data BLOB,width INTEGER DEFAULT 0,height INTEGER DEFAULT 0,last_requested INTEGER NOT NULL DEFAULT 0); \
    CREATE INDEX favicon_bitmaps_icon_id ON favicon_bitmaps(icon_id);";

/// Writes a database: `script` runs with `db` open; rows go in as
/// `(url, icon_id)` mappings and `(icon_id, hex png, width, last_updated)`
/// bitmaps.
fn database(
    path: &Path,
    schema: &str,
    mappings: &[(&str, i64)],
    bitmaps: &[(i64, Vec<u8>, i64, i64)],
) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let rows = serde_json::json!({
        "schema": schema,
        "mappings": mappings,
        "bitmaps": bitmaps.iter().map(|(id, data, w, t)| (id, hex(data), w, t)).collect::<Vec<_>>(),
        "chromium": schema == CHROMIUM_SCHEMA,
    });
    let script = r#"
import json, sqlite3, sys
spec = json.loads(sys.stdin.read())
db = sqlite3.connect(sys.argv[1])
db.executescript(spec["schema"])
for url, icon in spec["mappings"]:
    db.execute("INSERT INTO icon_mapping (page_url, icon_id) VALUES (?, ?)", (url, icon))
for icon, data, width, updated in spec["bitmaps"]:
    db.execute("INSERT INTO favicon_bitmaps (icon_id, image_data, width, height, last_updated) VALUES (?, ?, ?, ?, ?)",
               (icon, bytes.fromhex(data), width, width, updated))
db.commit()
db.close()
"#;
    let mut child = Command::new("python3")
        .args(["-c", script])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(rows.to_string().as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());
}

/// A "browser": a Python process holding `path` open after `script`, until
/// dropped. Waits for it to say it is ready.
struct Browser(Child);

impl Browser {
    fn hold(path: &Path, script: &str) -> Browser {
        let code = format!(
            "import sqlite3, sys\ndb = sqlite3.connect(sys.argv[1], isolation_level=None)\n{script}\nprint('ready', flush=True)\nsys.stdin.read()\n"
        );
        let mut child = Command::new("python3")
            .args(["-c", &code])
            .arg(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap())
            .read_line(&mut line)
            .unwrap();
        assert_eq!(line.trim(), "ready");
        Browser(child)
    }
}

impl Drop for Browser {
    fn drop(&mut self) {
        drop(self.0.stdin.take());
        let _ = self.0.wait();
    }
}

struct Setup {
    _dir: TempDir,
    config: PathBuf,
    dirs: Dirs,
}

fn setup(tag: &str) -> Setup {
    let dir = TempDir::new(tag);
    let config = dir.0.join("config");
    let dirs = Dirs {
        config: config.clone(),
        cache: dir.0.join("cache/foamy/browser-favicons"),
    };
    Setup {
        _dir: dir,
        config,
        dirs,
    }
}

fn request(host: &str) -> Value {
    serde_json::json!({"browser": "vivaldi", "hostname": host})
}

fn source_bytes(reply: &Reply) -> Vec<u8> {
    fs::read(reply.source.strip_prefix("file://").unwrap()).unwrap()
}

fn later() -> Instant {
    Instant::now() + Duration::from_secs(2)
}

#[test]
fn hostnames_follow_the_python_pattern() {
    for host in [
        "example.com",
        "teams.microsoft.com",
        "a.b",
        "1.com",
        "x-y.example.org",
    ] {
        assert!(valid_hostname(host), "{host}");
    }
    let long_label = format!("{}.com", "a".repeat(64));
    let long_name = format!("{}.com", vec!["a".repeat(60); 5].join("."));
    for host in [
        "",
        "localhost",
        "../secret",
        "https://example.com",
        "example.com:443",
        "example.com\nother.com",
        "Example.com",
        "example.com.",
        "-a.com",
        "a-.com",
        "example.123",
        "a..com",
        "exa_mple.com",
        &long_label,
        &long_name,
    ] {
        assert!(!valid_hostname(host), "{host:?}");
    }
}

#[test]
fn png_bounds() {
    assert!(valid_png(&png(32, 0)));
    assert!(valid_png(&png(256, MAX_ICON_BYTES)));
    assert!(!valid_png(&png(32, MAX_ICON_BYTES + 1)));
    assert!(!valid_png(&png(257, 0)));
    assert!(!valid_png(&png(0, 0)));
    assert!(!valid_png(&png(99999, 0)));
    assert!(!valid_png(&png(32, 0)[..23]));
    assert!(!valid_png(b"not a PNG at all, not even close"));
}

#[test]
fn sha256_and_uris_match_python() {
    assert_eq!(
        hex(&crate::hash::sha256(b"")),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        hex(&crate::hash::sha256(b"abc")),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    // hashlib.sha256(…).hexdigest()
    assert_eq!(
        hex(&crate::hash::sha256(b"vivaldi\nexample.com")),
        "61400a381a3bc23c14ba54c1a8543f9241ae78f58115e77d7c6f0450467a14b9"
    );
    let long: Vec<u8> = (0..1000u32).map(|i| i as u8).collect();
    assert_eq!(
        hex(&crate::hash::sha256(&long)),
        "a8af099bf2e878609558dbf69d8f88f4a31040a8cf84b549a0cfa912f12ffc3f"
    );
    assert_eq!(
        file_uri(Path::new("/home/a b/ø~_.-/x.png")).unwrap(),
        "file:///home/a%20b/%C3%B8~_.-/x.png"
    );
    assert!(file_uri(Path::new("relative/x.png")).is_err());
    assert_eq!(
        Reply::empty("not-found").to_line(),
        "{\"source\": \"\", \"status\": \"not-found\"}\n"
    );
}

#[test]
fn requests_are_checked_before_any_lookup() {
    let s = setup("favicon-request");
    let resolve = |request: Value| resolve(&request, &s.dirs);
    assert_eq!(
        resolve(serde_json::json!({"browser": "firefox", "hostname": "example.com"})).unwrap(),
        Reply::empty("unsupported-browser")
    );
    assert_eq!(
        resolve(serde_json::json!({"browser": 3})).unwrap().status,
        "unsupported-browser"
    );
    assert_eq!(
        resolve(serde_json::json!({"browser": ["vivaldi"]}))
            .unwrap_err()
            .code,
        "TypeError"
    );
    for host in [
        serde_json::json!("../secret"),
        serde_json::json!(7),
        Value::Null,
    ] {
        let request = serde_json::json!({"browser": "vivaldi", "hostname": host});
        assert_eq!(resolve(request).unwrap_err().code, "ValueError");
    }
    assert_eq!(request_from(b"[1]").unwrap_err().code, "ValueError");
    assert_eq!(request_from(b"{nope").unwrap_err().code, "JSONDecodeError");
    assert!(request_from(b"\xef\xbb\xbf{\"browser\": \"x\"}").is_ok());
    // No browser data: nothing found, nothing written.
    assert_eq!(
        resolve(request("example.com")).unwrap(),
        Reply::empty("not-found")
    );
    assert!(!s.dirs.cache.exists());
}

#[test]
fn finds_caches_and_reuses_a_private_png() {
    if !python() {
        return;
    }
    let s = setup("favicon-found");
    let icon = png(32, 3000);
    let path = s.config.join("vivaldi/Profile 1/Favicons");
    database(
        &path,
        TEST_SCHEMA,
        &[("https://teams.microsoft.com/chat", 1)],
        &[(1, icon.clone(), 32, 100)],
    );
    let reply = resolve(&request("teams.microsoft.com"), &s.dirs).unwrap();
    assert_eq!(reply.status, "found");
    assert_eq!(source_bytes(&reply), icon);
    let target = PathBuf::from(reply.source.strip_prefix("file://").unwrap());
    assert_eq!(fs::metadata(&target).unwrap().mode() & 0o777, 0o600);
    assert_eq!(fs::metadata(&s.dirs.cache).unwrap().mode() & 0o777, 0o700);
    fs::remove_file(&path).unwrap();
    assert_eq!(
        resolve(&request("teams.microsoft.com"), &s.dirs).unwrap(),
        Reply {
            source: reply.source.clone(),
            status: "cached"
        }
    );
    // A cache file that is no longer a valid PNG is not reused.
    fs::write(&target, b"garbage").unwrap();
    assert_eq!(
        resolve(&request("teams.microsoft.com"), &s.dirs)
            .unwrap()
            .status,
        "not-found"
    );
}

#[test]
fn hostname_bounds_do_not_match_other_sites() {
    if !python() {
        return;
    }
    let s = setup("favicon-bounds");
    database(
        &s.config.join("vivaldi/Profile 1/Favicons"),
        TEST_SCHEMA,
        &[
            ("https://teams.microsoft.com.evil.invalid/chat", 1),
            ("https://other.example.com/", 2),
            ("https://teams.microsoft.com0", 3),
        ],
        &[
            (1, png(32, 100), 32, 1),
            (2, png(32, 100), 32, 1),
            (3, png(32, 100), 32, 1),
        ],
    );
    assert_eq!(
        resolve(&request("teams.microsoft.com"), &s.dirs).unwrap(),
        Reply::empty("not-found")
    );
}

#[test]
fn missing_corrupt_and_oversized_icons_fall_back() {
    if !python() {
        return;
    }
    let s = setup("favicon-fallback");
    let path = s.config.join("vivaldi/Profile 1/Favicons");
    database(
        &path,
        TEST_SCHEMA,
        &[("https://example.com/", 1), ("http://example.com/", 2)],
        &[
            (1, vec![b'x'; 65537], 32, 1),
            (2, b"not a PNG".to_vec(), 32, 1),
        ],
    );
    assert_eq!(
        resolve(&request("example.com"), &s.dirs).unwrap(),
        Reply::empty("not-found")
    );
    fs::write(&path, b"corrupt database").unwrap();
    assert_eq!(
        resolve(&request("example.com"), &s.dirs).unwrap(),
        Reply::empty("cache-unavailable")
    );
}

#[test]
fn chromium_schema_prefers_32px_then_newest_and_reads_overflow_pages() {
    if !python() {
        return;
    }
    let s = setup("favicon-chromium");
    let path = s.config.join("vivaldi/Default/Favicons");
    let mut mappings: Vec<(String, i64)> = (0..3000)
        .map(|i| (format!("https://site{i}.example/page"), 1000 + i))
        .collect();
    mappings.push(("http://example.com/".into(), 1));
    mappings.push(("https://example.com/inbox".into(), 2));
    let mappings: Vec<(&str, i64)> = mappings.iter().map(|(u, i)| (u.as_str(), *i)).collect();
    let wanted = png(32, 20_000); // several overflow pages
    database(
        &path,
        CHROMIUM_SCHEMA,
        &mappings,
        &[
            (1, png(32, 200), 32, 900),    // http only: https wins first
            (2, png(16, 200), 16, 999),    // further from 32
            (2, png(32, 300), 32, 100),    // older
            (2, wanted.clone(), 32, 500),  // the newest 32 px
            (2, png(300, 200), 300, 2000), // too large
            (1500, png(32, 100), 32, 1),
        ],
    );
    let found = lookup("vivaldi", "example.com", &s.config);
    assert_eq!((found.data == wanted, found.unavailable), (true, false));
    // Only the http:// mapping: it is used when https has none.
    let only_http = lookup("vivaldi", "site7.example", &s.config);
    assert!(only_http.data.is_empty() && !only_http.unavailable);
}

#[test]
fn locked_cache_is_copied_without_touching_browser_files() {
    if !python() {
        return;
    }
    let s = setup("favicon-locked");
    let icon = png(32, 500);
    let path = s.config.join("vivaldi/Profile 1/Favicons");
    database(
        &path,
        TEST_SCHEMA,
        &[("https://example.com/mail", 1)],
        &[(1, icon.clone(), 32, 100)],
    );
    let before = fs::read(&path).unwrap();
    let browser = Browser::hold(
        &path,
        "db.execute('PRAGMA locking_mode=EXCLUSIVE')\ndb.execute('BEGIN EXCLUSIVE')\ndb.execute('COMMIT')",
    );
    assert_eq!(
        Database::open_live(&path, later()).err(),
        Some(Fault::Busy),
        "the browser's exclusive lock is seen"
    );
    let reply = resolve(&request("example.com"), &s.dirs).unwrap();
    assert_eq!(reply.status, "found");
    assert_eq!(source_bytes(&reply), icon);
    // A separate reader still sees the browser's lock.
    let probe = Command::new("python3")
        .args(["-c", "import sqlite3,sys; sqlite3.connect(sys.argv[1], timeout=0).execute('SELECT * FROM icon_mapping').fetchall()"])
        .arg(&path)
        .stderr(Stdio::piped())
        .output()
        .unwrap();
    assert!(
        !probe.status.success()
            && String::from_utf8_lossy(&probe.stderr).contains("database is locked")
    );
    drop(browser);
    assert_eq!(fs::read(&path).unwrap(), before);
    let names: Vec<_> = fs::read_dir(path.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(names, ["Favicons"]);
}

#[test]
fn uncommitted_transactions_and_sidecars_are_not_copied() {
    if !python() {
        return;
    }
    let s = setup("favicon-transaction");
    let path = s.config.join("vivaldi/Profile 1/Favicons");
    database(
        &path,
        TEST_SCHEMA,
        &[("https://example.com/", 1)],
        &[(1, png(32, 100), 32, 100)],
    );
    let before = fs::read(&path).unwrap();
    {
        let _browser = Browser::hold(
            &path,
            "db.execute('BEGIN EXCLUSIVE')\ndb.execute(\"UPDATE favicon_bitmaps SET image_data = x'00'\")",
        );
        assert!(fs::metadata(sidecar(&path, "-journal")).unwrap().len() > 0);
        assert_eq!(
            resolve(&request("example.com"), &s.dirs).unwrap(),
            Reply::empty("cache-unavailable")
        );
    }
    assert_eq!(fs::read(&path).unwrap(), before);
    let _browser = Browser::hold(
        &path,
        "db.execute('PRAGMA locking_mode=EXCLUSIVE')\ndb.execute('BEGIN EXCLUSIVE')\ndb.execute('COMMIT')",
    );
    for (suffix, data) in [
        ("-journal", &b"active journal"[..]),
        ("-wal", b""),
        ("-shm", b""),
    ] {
        let car = sidecar(&path, suffix);
        fs::write(&car, data).unwrap();
        assert_eq!(
            resolve(&request("example.com"), &s.dirs).unwrap(),
            Reply::empty("cache-unavailable"),
            "{suffix}"
        );
        assert_eq!(fs::read(&car).unwrap(), data);
        fs::remove_file(&car).unwrap();
    }
}

#[test]
fn hot_journal_is_unavailable_like_a_read_only_connection() {
    if !python() {
        return;
    }
    let s = setup("favicon-hot");
    let path = s.config.join("vivaldi/Favicons");
    database(
        &path,
        TEST_SCHEMA,
        &[("https://example.com/", 1)],
        &[(1, png(32, 100), 32, 100)],
    );
    let journal = sidecar(&path, "-journal");
    fs::write(&journal, [0u8; 512]).unwrap();
    assert_eq!(
        lookup("vivaldi", "example.com", &s.config).data.len(),
        100,
        "a zeroed journal is not hot"
    );
    let mut hot = vec![0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7];
    hot.resize(512, 0);
    fs::write(&journal, hot).unwrap();
    assert_eq!(
        lookup("vivaldi", "example.com", &s.config),
        Lookup {
            data: Vec::new(),
            unavailable: true
        }
    );
}

#[test]
fn wal_cache_includes_committed_frames() {
    if !python() {
        return;
    }
    let s = setup("favicon-wal");
    let path = s.config.join("vivaldi/Profile 1/Favicons");
    database(&path, TEST_SCHEMA, &[], &[]);
    let icon = png(32, 9000);
    let insert = format!(
        "db.execute('PRAGMA journal_mode=WAL')\ndb.execute('BEGIN')\ndb.execute(\"INSERT INTO icon_mapping VALUES ('https://example.com/', 1)\")\ndb.execute(\"INSERT INTO favicon_bitmaps VALUES (1, x'{}', 32, 32, 100)\")\ndb.execute('COMMIT')\ndb.execute('BEGIN')\ndb.execute(\"UPDATE favicon_bitmaps SET width = 999\")",
        hex(&icon)
    );
    let _browser = Browser::hold(&path, &insert);
    assert!(fs::metadata(sidecar(&path, "-wal")).unwrap().len() > 0);
    let reply = resolve(&request("example.com"), &s.dirs).unwrap();
    assert_eq!(
        reply.status, "found",
        "the uncommitted update is not visible"
    );
    assert_eq!(source_bytes(&reply), icon);
}

#[test]
fn guarded_copy_checks_changes_limits_and_symlinks() {
    if !python() {
        return;
    }
    let s = setup("favicon-copy");
    let path = s.config.join("vivaldi/Profile 1/Favicons");
    database(
        &path,
        TEST_SCHEMA,
        &[("https://example.com/", 1)],
        &[(1, png(32, 100), 32, 100)],
    );
    let state = snapshot_state(&path).unwrap();
    let mut changed = state;
    changed[0] = changed[0].map(|(d, i, s, m, c)| (d, i, s, m + 1, c));
    let sequence = |states: Vec<[Option<FileState>; 4]>| {
        let mut states = states.into_iter();
        move |_: &Path| Ok(states.next().unwrap())
    };
    assert!(
        copy_snapshot_with(
            &path,
            later(),
            &mut sequence(vec![state, changed, state, changed])
        )
        .is_err()
    );
    assert_eq!(
        copy_snapshot_with(
            &path,
            later(),
            &mut sequence(vec![state, changed, state, state])
        )
        .unwrap(),
        fs::read(&path).unwrap()
    );
    assert!(copy_snapshot(&path, Instant::now() - Duration::from_millis(1)).is_err());
    let alias = path.parent().unwrap().join("alias");
    std::os::unix::fs::symlink(&path, &alias).unwrap();
    assert!(copy_snapshot(&alias, later()).is_err());
    let big = s.config.join("big");
    fs::write(&big, vec![0u8; MAX_DATABASE_BYTES as usize + 1]).unwrap();
    assert!(copy_snapshot(&big, later()).is_err());
    std::os::unix::fs::symlink(&path, sidecar(&path, "-journal")).unwrap();
    assert!(copy_snapshot(&path, later()).is_err());
}

#[test]
fn empty_journal_is_allowed_but_a_wal_header_and_corruption_are_not() {
    if !python() {
        return;
    }
    let s = setup("favicon-header");
    let path = s.config.join("vivaldi/Profile 1/Favicons");
    let icon = png(32, 100);
    database(
        &path,
        TEST_SCHEMA,
        &[("https://example.com/", 1)],
        &[(1, icon.clone(), 32, 100)],
    );
    fs::write(sidecar(&path, "-journal"), b"").unwrap();
    assert_eq!(locked_favicon(&path, "example.com", later()).unwrap(), icon);
    let image = fs::read(&path).unwrap();
    let mut corrupt = image.clone();
    corrupt[100] = 0xff;
    assert!(favicon_in_image(corrupt, "example.com", later()).is_err());
    let mut wal = image;
    wal[18..20].copy_from_slice(&[2, 2]);
    fs::write(&path, &wal).unwrap();
    assert!(locked_favicon(&path, "example.com", later()).is_err());
}

#[test]
fn whole_contract_through_a_pipe() {
    // `run` itself is exercised by the fixture plugin's helper; here the
    // reply lines it prints.
    let s = setup("favicon-lines");
    let reply = resolve(
        &serde_json::json!({"browser": "opera", "hostname": "example.com"}),
        &s.dirs,
    )
    .unwrap();
    let mut out = Vec::new();
    out.write_all(reply.to_line().as_bytes()).unwrap();
    assert_eq!(out, b"{\"source\": \"\", \"status\": \"not-found\"}\n");
}
