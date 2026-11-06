//! The archive under `$NC_STORE` and the one-shot commands. Each function
//! mirrors one function of the former `bin/notification-center`, including
//! which malformed rows make a step fail (jq stopped there) and which are
//! skipped (`fromjson?`).

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use foamy_helper::lock::FileLock;
use rustix::fs::OFlags;

use crate::images::Images;
use crate::json::{self, Dialect, Value};
use crate::{casefold, text};

/// A step failed (the old function's `return 1`); the command reports it.
#[derive(Debug)]
pub struct Bad;
pub type Step<T = ()> = Result<T, Bad>;

impl From<json::JqError> for Bad {
    fn from(_: json::JqError) -> Bad {
        Bad
    }
}

pub const DAY_MS: i128 = 86_400_000;

pub fn now_ms() -> i128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i128)
}

/// One line on standard output, flushed (the watcher's stream). A reader
/// that went away ends the helper, as SIGPIPE ended the script.
pub fn print_line(text: &str) {
    let mut out = io::stdout().lock();
    if writeln!(out, "{text}").and_then(|()| out.flush()).is_err() {
        std::process::exit(1);
    }
}

/// `[[ -s path ]]`.
pub fn nonempty(path: &str) -> bool {
    fs::metadata(path).is_ok_and(|m| m.len() > 0)
}

/// jq -R's inputs: the lines of a file, the last one also without its newline.
pub fn lines(data: &[u8]) -> Vec<&[u8]> {
    let mut out: Vec<&[u8]> = data.split(|&b| b == b'\n').collect();
    if out.last().is_some_and(|l| l.is_empty()) {
        out.pop();
    }
    out
}

/// `fromjson?` on one line.
pub fn row(line: &[u8]) -> Option<Value> {
    json::parse(line, Dialect::Jq)
}

/// A `jq -R` program over a file's lines: each line (`fromjson?` applied)
/// gives outputs or a runtime error. jq skips a failing line and exits
/// non-zero only when the *last* line failed, so that is what `failed` says.
pub fn per_line(
    data: &[u8],
    mut program: impl FnMut(Option<Value>) -> json::Jq<Vec<String>>,
) -> (Vec<String>, bool) {
    let mut out = Vec::new();
    let mut failed = false;
    for line in lines(data) {
        match program(row(line)) {
            Ok(lines) => {
                out.extend(lines);
                failed = false;
            }
            Err(_) => failed = true,
        }
    }
    (out, failed)
}

/// `$set[key]` for an object built with `INDEX(.)`: only strings index it.
fn indexed(set: &[String], key: &Value) -> json::Jq<bool> {
    match key {
        Value::Str(k) => Ok(set.iter().any(|s| s == k)),
        _ => Err(json::JqError),
    }
}

fn joined(rows: &[String]) -> Vec<u8> {
    let mut out = String::new();
    for row in rows.iter().filter(|r| !r.is_empty()) {
        out.push_str(row);
        out.push('\n');
    }
    out.into_bytes()
}

fn read_file(path: &str) -> Step<Vec<u8>> {
    fs::read(path).map_err(|_| Bad)
}

/// `$(<file)` / `$(cat file)`.
fn slurp(path: &str) -> Option<String> {
    fs::read(path)
        .ok()
        .map(|data| text::cmdsub(&String::from_utf8_lossy(&data)))
}

fn write_atomic(path: &str, data: &[u8]) -> Step {
    foamy_helper::fs::write_atomic(Path::new(path), data, 0o600).map_err(|error| {
        eprintln!("notification-center: {error}");
        Bad
    })
}

/// `>> path`, ending an unterminated last line first so two records never merge.
fn append(path: &str, data: &[u8]) -> Step {
    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(OFlags::NOFOLLOW.bits() as i32)
        .open(path)
        .map_err(|_| Bad)?;
    let unterminated = fs::read(path)
        .map_err(|_| Bad)?
        .last()
        .is_some_and(|&b| b != b'\n');
    let mut out = Vec::with_capacity(data.len() + 1);
    if unterminated {
        out.push(b'\n');
    }
    out.extend_from_slice(data);
    file.write_all(&out).map_err(|_| Bad)
}

/// Appends one JSON line.
pub fn append_line(path: &str, line: &str) -> Step {
    append(path, format!("{line}\n").as_bytes())
}

fn remove_quiet(path: &str) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

pub struct Store {
    pub source_kind: String,
    pub src_dir: String,
    pub src_history: String,
    pub source_state_dir: String,
    pub src_tag: String,
    pub handled: String,
    pub dnd_files: Vec<String>,
    pub dir: String,
    pub archive: String,
    pub images: String,
    pub seen: String,
    pub lock: String,
    pub dismissed: String,
    pub cleared_at: String,
    pub pruned_through: String,
    pub keep_days: i128,
    pub max_items: i128,
    /// `NC_PREVIEWS` as given: part of the asset hashes.
    pub previews_raw: String,
    pub previews: bool,
    pub policy_dir: String,
    /// Under `watch`: retention reports pruned Foamy keys.
    pub watching: bool,
    /// `sync` prints only its summary line, not the rows it took in.
    pub quiet: bool,
    /// The last ingest appended a row.
    pub ingest_added: bool,
}

fn var(name: &str) -> Option<String> {
    std::env::var_os(name)
        .map(|v| v.to_string_lossy().into_owned())
        .filter(|v| !v.is_empty())
}

/// An integer setting; anything else is the default.
fn integer(name: &str, default: i128) -> i128 {
    var(name)
        .and_then(|v| {
            let digits = v.strip_prefix('-').unwrap_or(&v);
            text::all_digits(digits).then(|| {
                let n = text::decimal(digits);
                if v.starts_with('-') { -n } else { n }
            })
        })
        .unwrap_or(default)
}

impl Store {
    pub fn from_env(policy_dir: String) -> Store {
        let home = std::env::var_os("HOME")
            .map(|v| v.to_string_lossy().into_owned())
            .unwrap_or_default();
        let state_home = var("XDG_STATE_HOME").unwrap_or_else(|| format!("{home}/.local/state"));
        let src_dir = var("NC_SRC_DIR")
            .unwrap_or_else(|| format!("{home}/.local/state/omarchy/notifications"));
        let src_history = var("NC_SRC_HISTORY").unwrap_or_else(|| format!("{src_dir}/history"));
        let source_state_dir = text::dirname(&src_dir);
        let dnd_files = match var("NC_STATE_FILE") {
            Some(file) => vec![file],
            None => vec![
                format!("{source_state_dir}/notifications.json"),
                format!("{src_dir}/quiet.json"),
            ],
        };
        let dir =
            var("NC_STORE").unwrap_or_else(|| format!("{state_home}/omarchy-notification-center"));
        let previews_raw = var("NC_PREVIEWS").unwrap_or_else(|| "1".into());
        let previews = integer("NC_PREVIEWS", 1) != 0
            && text::all_digits(previews_raw.trim_start_matches('-'));
        Store {
            source_kind: var("NC_SOURCE").unwrap_or_else(|| "stock".into()),
            src_tag: text::cksum(src_dir.as_bytes()).to_string(),
            src_history,
            source_state_dir,
            handled: var("NC_HANDLED").unwrap_or_default(),
            dnd_files,
            archive: format!("{dir}/archive.jsonl"),
            images: format!("{dir}/images"),
            seen: format!("{dir}/seen"),
            lock: format!("{dir}/lock"),
            dismissed: format!("{dir}/dismissed"),
            cleared_at: format!("{dir}/cleared_at"),
            pruned_through: format!("{dir}/pruned_through"),
            dir,
            src_dir,
            keep_days: integer("NC_KEEP_DAYS", 30),
            max_items: integer("NC_MAX_ITEMS", 1000),
            previews_raw,
            previews,
            policy_dir,
            watching: false,
            quiet: false,
            ingest_added: false,
        }
    }

    pub fn images(&self) -> Images<'_> {
        Images {
            dir: &self.images,
            policy_dir: &self.policy_dir,
        }
    }

    pub fn cutoff(&self) -> i128 {
        now_ms().saturating_sub(self.keep_days.saturating_mul(DAY_MS))
    }

    /// An archived row as the watcher streams it (not for a plain `sync`).
    pub fn entry(&self, line: &str) {
        if !self.quiet {
            print_line(line);
        }
    }

    /// One writer at a time, for as long as one step takes (`flock` on `$store/lock`).
    pub fn locked<T>(&mut self, step: impl FnOnce(&mut Store) -> Step<T>) -> Step<T> {
        let _lock = FileLock::exclusive(Path::new(&self.lock)).map_err(|error| {
            eprintln!("notification-center: {error}");
            Bad
        })?;
        step(self)
    }

    /// `ensure_store`: the private store, its archive and tombstone files.
    pub fn ensure(&self) -> Result<(), String> {
        for dir in [&self.dir, &self.images] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)
                .map_err(|_| format!("cannot create {}", self.dir))?;
        }
        for file in [&self.archive, &self.dismissed] {
            if !fs::metadata(file).is_ok_and(|m| m.is_file()) {
                let _ = OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(true)
                    .mode(0o600)
                    .custom_flags(OFlags::NOFOLLOW.bits() as i32)
                    .open(file);
            }
        }
        // Installs that predate the umask created these 755 and 644.
        let tighten = |path: &str, mode: u32| {
            if let Ok(meta) = fs::symlink_metadata(path)
                && !meta.file_type().is_symlink()
            {
                let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
            }
        };
        tighten(&self.dir, 0o700);
        tighten(&self.images, 0o700);
        for file in [
            &self.archive,
            &self.dismissed,
            &self.seen,
            &self.cleared_at,
            &self.pruned_through,
        ] {
            tighten(file, 0o600);
        }
        Ok(())
    }

    // ------------------------------------------------- durable exclusions

    /// The clear line: everything at or before it stays out.
    pub fn cleared_line(&self) -> i128 {
        if !nonempty(&self.cleared_at) {
            return 0;
        }
        slurp(&self.cleared_at)
            .filter(|t| text::all_digits(t))
            .map_or(0, |t| text::decimal(&t))
    }

    /// The retention watermark "TS KEY" (an older bare "TS" ranks below every key of its ts).
    pub fn watermark(&self) -> (i128, String) {
        let line = if nonempty(&self.pruned_through) {
            fs::read(&self.pruned_through)
                .ok()
                .map(|d| {
                    String::from_utf8_lossy(d.split(|&b| b == b'\n').next().unwrap_or(&[]))
                        .into_owned()
                })
                .unwrap_or_default()
        } else {
            String::new()
        };
        let (ts, key) = match line.split_once(' ') {
            Some((ts, key)) => (ts, Some(key)),
            None => (line.as_str(), None),
        };
        let key_ok = key.is_none_or(|k| {
            !k.is_empty()
                && k.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        });
        if text::all_digits(ts) && key_ok {
            (text::decimal(ts), key.unwrap_or("").to_string())
        } else {
            (0, String::new())
        }
    }

    /// Whether `(ts1, key1) <= (ts2, key2)`, keys bytewise.
    pub fn rank_le(ts1: i128, key1: &str, ts2: i128, key2: &str) -> bool {
        ts1 < ts2 || (ts1 == ts2 && key1.as_bytes() <= key2.as_bytes())
    }

    /// I1 for a ts-id key absent from the archive: covered by its stamp alone.
    pub fn stamp_excluded(&self, key: &str) -> bool {
        let Some(stamp) = text::key_stamp(key) else {
            return false;
        };
        let stamp = text::decimal(stamp);
        if stamp <= self.cleared_line() || stamp < self.cutoff() {
            return true;
        }
        let (wm_ts, wm_key) = self.watermark();
        Store::rank_le(stamp, key, wm_ts, &wm_key)
    }

    /// `is_dismissed`: a tombstone, or a ts-id stamp at or below the clear line.
    pub fn is_dismissed(&self, key: &str) -> bool {
        if key.is_empty() {
            return false;
        }
        if nonempty(&self.dismissed)
            && let Ok(data) = fs::read(&self.dismissed)
        {
            let found = data.split(|&b| b == b'\n').any(|line| {
                line.strip_prefix(key.as_bytes())
                    .is_some_and(|rest| rest.is_empty() || rest[0] == b' ')
            });
            if found {
                return true;
            }
        }
        if nonempty(&self.cleared_at)
            && let Some(cleared) = slurp(&self.cleared_at).filter(|t| text::all_digits(t))
        {
            let cleared = text::decimal(&cleared);
            let stamp = key.split('-').next().unwrap_or("");
            if cleared > 0 && text::all_digits(stamp) && text::decimal(stamp) <= cleared {
                return true;
            }
        }
        false
    }

    /// Tombstones ("KEY TS REMOVED_AT SOURCE"), each key written once, from
    /// "KEY TS" lines.
    pub fn add_tombstones(&self, stones: &[String]) -> Step {
        let existing = read_file(&self.dismissed)?;
        let mut seen: Vec<String> = text::lines_text(&existing)
            .iter()
            .filter_map(|l| text::fields(l).first().map(|f| f.to_string()))
            .collect();
        let now = now_ms();
        let mut out = String::new();
        for stone in stones {
            for line in stone.split('\n') {
                let f = text::fields(line);
                let Some(key) = f.first() else {
                    continue;
                };
                if seen.iter().any(|s| s == key) {
                    continue;
                }
                seen.push(key.to_string());
                let ts = f.get(1).copied().unwrap_or("0");
                out.push_str(&format!("{key} {ts} {now} {}\n", self.src_tag));
            }
        }
        if out.is_empty() {
            Ok(())
        } else {
            append(&self.dismissed, out.as_bytes())
        }
    }

    /// Drop ts-id tombstones a durable exclusion now covers (never the age limit).
    pub fn trim_tombstones(&self) {
        if !nonempty(&self.dismissed) {
            return;
        }
        let cleared = self.cleared_line() as f64;
        let (wm_ts, wm_key) = self.watermark();
        let wm_ts = wm_ts as f64;
        let Ok(data) = fs::read(&self.dismissed) else {
            return;
        };
        let mut out = String::new();
        for line in text::lines_text(&data) {
            let first = text::fields(&line).first().copied().unwrap_or("");
            if text::ts_id(first) {
                let ts = text::awk_number(first.split('-').next().unwrap_or(""));
                if ts <= cleared
                    || ts < wm_ts
                    || (ts == wm_ts && first.as_bytes() <= wm_key.as_bytes())
                {
                    continue;
                }
            }
            out.push_str(&line);
            out.push('\n');
        }
        let _ = write_atomic(&self.dismissed, out.as_bytes());
    }

    /// Drop tombstones of keys no file of their own source holds any more, an
    /// hour or more after the removal. Runs after a complete sync.
    pub fn trim_absent_tombstones(&self) {
        if !nonempty(&self.dismissed) || !fs::metadata(&self.src_dir).is_ok_and(|m| m.is_dir()) {
            return;
        }
        let mut here: Vec<String> = Vec::new();
        for dir in [&self.src_dir, &self.src_history] {
            for name in json_files(dir) {
                let stem = name.strip_suffix(".json").unwrap_or(&name);
                if let Some(first) = text::fields(stem).first() {
                    here.push(first.to_string());
                }
            }
        }
        if self.source_kind == "stock" {
            for name in ["live.json", "history.json"] {
                let file = format!("{}/{name}", self.src_dir);
                if !nonempty(&file) {
                    continue;
                }
                match crate::stock::present_keys(Path::new(&file)) {
                    Ok(keys) => here.extend(keys),
                    Err(error) => {
                        eprintln!(
                            "notification-center: cannot read stock notification array ({})",
                            error.0
                        );
                        return;
                    }
                }
            }
        }
        let grace = (now_ms() - 3_600_000) as f64;
        let Ok(data) = fs::read(&self.dismissed) else {
            return;
        };
        let mut out = String::new();
        for line in text::lines_text(&data) {
            let f = text::fields(&line);
            let field = |i: usize| f.get(i).copied().unwrap_or("");
            if text::awk_equal(field(3), &self.src_tag)
                && !here.iter().any(|h| h == field(0))
                && text::awk_number(field(2)) < grace
            {
                continue;
            }
            out.push_str(&line);
            out.push('\n');
        }
        let _ = write_atomic(&self.dismissed, out.as_bytes());
    }

    // --------------------------------------------------------- handled

    /// The first 64 KiB of Foamy's handled journal, line by line.
    fn handled_lines(&self) -> Vec<String> {
        if self.handled.is_empty() || !nonempty(&self.handled) {
            return Vec::new();
        }
        crate::ingest::read_regular(&self.handled, 65_536)
            .map(|data| text::lines_text(&data))
            .unwrap_or_default()
    }

    pub fn handled_listed(&self, key: &str) -> bool {
        text::ts_id(key) && self.handled_lines().iter().any(|line| line == key)
    }

    /// Foamy's handled journal (contract v2): remove what it lists.
    pub fn apply_handled(&mut self) -> Step {
        if self.handled.is_empty() || !nonempty(&self.handled) || !nonempty(&self.archive) {
            return Ok(());
        }
        let listed: Vec<String> = self
            .handled_lines()
            .into_iter()
            .filter(|l| text::ts_id(l))
            .collect();
        let (values, _) = json::parse_stream(&read_file(&self.archive)?);
        let mut keys = Vec::new();
        for value in values {
            let Ok(key) = value.field("key") else {
                continue;
            };
            match key {
                Value::Str(k) if listed.contains(&k) => keys.push(k),
                Value::Str(_) => {}
                _ => continue,
            }
        }
        if keys.is_empty() {
            return Ok(());
        }
        self.remove_keys(&keys)
    }

    // --------------------------------------------------------- removing

    fn image_copies(&self, key: &str) -> [String; 6] {
        let i = &self.images;
        [
            format!("{i}/{key}-appIcon"),
            format!("{i}/{key}-image"),
            format!("{i}/{key}-preview"),
            format!("{i}/{key}-appIcon.png"),
            format!("{i}/{key}-image.png"),
            format!("{i}/{key}-preview.png"),
        ]
    }

    fn drop_images(&self, key: &str) {
        if text::valid_key(key) {
            for copy in self.image_copies(key) {
                let _ = remove_quiet(&copy);
            }
        }
    }

    /// One locked rewrite for any number of keys; tombstones with the
    /// archived timestamp (else the key's stamp, else 0); our image copies go.
    pub fn remove_keys(&mut self, keys: &[String]) -> Step {
        let data = read_file(&self.archive)?;
        let found = |value: &Value| -> json::Jq<bool> { indexed(keys, &value.field("key")?) };
        let (kept, failed) = per_line(&data, |row| match row {
            Some(value) if !found(&value)? => Ok(vec![json::jq(&value)]),
            _ => Ok(Vec::new()),
        });
        let (mut stones, _) = per_line(&data, |row| match row {
            Some(value) if found(&value)? => {
                let ts = value.field("timestamp")?.or(Value::int(0));
                Ok(vec![format!(
                    "{} {}",
                    json::tostring(&value.field("key")?),
                    json::tostring(&ts)
                )])
            }
            _ => Ok(Vec::new()),
        });
        if failed {
            return Err(Bad);
        }
        for key in keys {
            stones.push(format!("{key} {}", text::key_stamp(key).unwrap_or("0")));
        }
        self.add_tombstones(&stones)?;
        write_atomic(&self.archive, &joined(&kept))?;
        for key in keys {
            for copy in self.image_copies(key) {
                remove_quiet(&copy).map_err(|_| Bad)?;
            }
        }
        Ok(())
    }

    /// Clear deletes every archived row up to the cutoff and its images; the
    /// clear line stays (and only rises).
    pub fn clear_all(&mut self, cut: Option<&str>) -> Step {
        let now = now_ms();
        let stamp = cut
            .filter(|c| c.len() <= 16 && text::all_digits(c))
            .map(text::decimal)
            .filter(|&s| s <= now)
            .unwrap_or(now);
        if self.cleared_line() <= stamp {
            let _ = write_atomic(&self.cleared_at, format!("{stamp}\n").as_bytes());
        }
        if !nonempty(&self.archive) {
            return Ok(());
        }
        let data = read_file(&self.archive)?;
        let cut = Value::int(stamp);
        // `fromjson? // empty`, then the row's `.timestamp // 0` against the cut.
        let after = |row: &Option<Value>| -> json::Jq<Option<bool>> {
            match row.as_ref().filter(|v| v.truthy()) {
                Some(value) => Ok(Some(json::gt(
                    &value.field("timestamp")?.or(Value::int(0)),
                    &cut,
                ))),
                None => Ok(None),
            }
        };
        let (kept, kept_failed) = per_line(&data, |row| {
            Ok(match (after(&row)?, row) {
                (Some(true), Some(value)) => vec![json::jq(&value)],
                _ => Vec::new(),
            })
        });
        let (dropped, _) = per_line(&data, |row| {
            Ok(match (after(&row)?, row) {
                (Some(false), Some(value)) => vec![json::jq_raw(&value.field("key")?)],
                _ => Vec::new(),
            })
        });
        let (stones, stones_failed) = per_line(&data, |row| {
            let Some(false) = after(&row)? else {
                return Ok(Vec::new());
            };
            let value = row.unwrap_or(Value::Null);
            let key = value.field("key")?;
            let Value::Str(k) = &key else {
                return Err(json::JqError);
            };
            if !k.starts_with("stock-") {
                return Ok(Vec::new());
            }
            Ok(vec![format!(
                "{k} {}",
                json::tostring(&value.field("timestamp")?.or(Value::int(0)))
            )])
        });
        if kept_failed || stones_failed {
            return Err(Bad);
        }
        if !stones.is_empty() {
            self.add_tombstones(&stones)?;
        }
        write_atomic(&self.archive, &joined(&kept))?;
        for key in dropped.iter().flat_map(|k| k.split('\n')) {
            self.drop_images(key);
        }
        Ok(())
    }

    // --------------------------------------------------------- retention

    /// Whether a limit can have been crossed: more rows than the ceiling, or
    /// a `"timestamp":<digits>` older than the age limit.
    pub fn prune_needed(&self) -> bool {
        if !nonempty(&self.archive) {
            return false;
        }
        let Ok(data) = fs::read(&self.archive) else {
            return false;
        };
        let cutoff = self.cutoff() as f64;
        let records = text::lines_text(&data);
        let old = records.iter().any(|line| {
            let mut from = 0;
            while let Some(at) = line[from..].find("\"timestamp\":") {
                let digits_at = from + at + 12;
                let digits: String = line[digits_at..]
                    .chars()
                    .take_while(char::is_ascii_digit)
                    .collect();
                if !digits.is_empty() {
                    return text::awk_number(&digits) < cutoff;
                }
                from = from + at + 1;
            }
            false
        });
        records.len() as i128 > self.max_items || old
    }

    /// Retention: the newest `max_items` rows younger than `keep_days`, by
    /// rank; the watermark rises to the highest dropped rank; dropped stock
    /// keys get tombstones; dropped Foamy keys are reported under `watch`.
    pub fn prune(&mut self) -> Step {
        self.trim_tombstones();
        if !nonempty(&self.archive) {
            return Ok(());
        }
        let Ok(data) = read_file(&self.archive) else {
            return Ok(());
        };
        let Some((kept, dropped)) = self.verdict(&data) else {
            return Ok(());
        };
        // I3: the watermark only rises.
        let top = dropped
            .iter()
            .fold(None::<&(Value, Value)>, |best, item| match best {
                Some(b) if json::cmp(&key_rank(item), &key_rank(b)) == std::cmp::Ordering::Less => {
                    Some(b)
                }
                _ => Some(item),
            });
        if let Some((key, ts)) = top {
            let top_ts = text::cmdsub(&json::jq_raw(ts));
            let top_key = text::cmdsub(&json::jq_raw(key));
            let (wm_ts, wm_key) = self.watermark();
            if text::all_digits(&top_ts)
                && !top_key.is_empty()
                && !Store::rank_le(text::decimal(&top_ts), &top_key, wm_ts, &wm_key)
            {
                let _ = write_atomic(
                    &self.pruned_through,
                    format!("{top_ts} {top_key}\n").as_bytes(),
                );
            }
        }
        let stones: Vec<String> = dropped
            .iter()
            .filter_map(|(key, ts)| match key {
                Value::Str(k) if k.starts_with("stock-") => {
                    Some(format!("{k} {}", json::tostring(ts)))
                }
                _ => None,
            })
            .collect();
        if !stones.is_empty() {
            let _ = self.add_tombstones(&stones);
        }
        let _ = write_atomic(&self.archive, &joined(&kept));
        let mut pruned = Vec::new();
        for (key, _) in &dropped {
            let key = text::cmdsub(&json::jq_raw(key));
            self.drop_images(&key);
            if text::ts_id(&key) {
                pruned.push(key);
            }
        }
        // The source's own copies are its business: the service asks Foamy to drop them.
        if self.watching && !pruned.is_empty() && self.source_kind != "stock" {
            for chunk in pruned.chunks(1000) {
                let keys = Value::Arr(chunk.iter().map(|k| Value::str(k.clone())).collect());
                print_line(&format!(
                    "{{\"event\":\"pruned\",\"keys\":{}}}",
                    json::jq(&keys)
                ));
            }
        }
        Ok(())
    }

    /// The retention verdict: (kept rows as lines, dropped (key, timestamp)),
    /// or None where jq failed (nothing is pruned then).
    fn verdict(&self, data: &[u8]) -> Option<Verdict> {
        let rows: Vec<Value> = lines(data)
            .into_iter()
            .filter_map(row)
            .filter(|v| matches!(v, Value::Obj(_)) && v.field("key").is_ok_and(|k| k.truthy()))
            .collect();
        let ts = |v: &Value| {
            v.field("timestamp")
                .unwrap_or(Value::Null)
                .or(Value::int(0))
        };
        let cutoff = Value::int(self.cutoff());
        let mut fresh: Vec<&Value> = rows
            .iter()
            .filter(|v| json::cmp(&ts(v), &cutoff) != std::cmp::Ordering::Less)
            .collect();
        fresh.sort_by(|a, b| {
            json::cmp(
                &Value::Arr(vec![ts(a), a.field("key").unwrap_or(Value::Null)]),
                &Value::Arr(vec![ts(b), b.field("key").unwrap_or(Value::Null)]),
            )
        });
        let len = fresh.len() as i128;
        let kept: Vec<&Value> = if len > self.max_items {
            let start = len - self.max_items;
            if start >= len {
                Vec::new()
            } else {
                fresh[start as usize..].to_vec()
            }
        } else {
            fresh
        };
        let keep: Vec<String> = kept
            .iter()
            .map(|v| json::tostring(&v.field("key").unwrap_or(Value::Null)))
            .collect();
        let mut dropped = Vec::new();
        for v in &rows {
            let key = v.field("key").ok()?;
            let Value::Str(k) = &key else {
                return None;
            };
            if !keep.contains(k) {
                dropped.push((key.clone(), ts(v)));
            }
        }
        Some((kept.iter().map(|v| json::jq(v)).collect(), dropped))
    }

    // --------------------------------------------------------- migrations

    /// Older records may outlive their sender files: convert their retained
    /// copies before any list is returned. New URLs avoid Qt reusing a
    /// cached original.
    pub fn normalize_archive(&mut self) -> Step {
        let data = read_file(&self.archive)?;
        let (pending, failed) = per_line(&data, |row| {
            let Some(value) = row else {
                return Ok(Vec::new());
            };
            let format = value.field("imageFormat")?;
            if matches!(&format, Value::Num(n) if n.f64() == 1.0) {
                return Ok(Vec::new());
            }
            let pathlike = ["appIcon", "image", "preview"]
                .iter()
                .any(|slot| matches!(value.field(slot), Ok(Value::Str(s)) if s.contains('/') || s.contains(':')));
            Ok(if pathlike {
                vec![json::jq(&value)]
            } else {
                Vec::new()
            })
        });
        if failed {
            return Err(Bad);
        }
        if pending.is_empty() {
            return Ok(());
        }
        let pending: Vec<Value> = pending
            .iter()
            .filter_map(|line| row(line.as_bytes()))
            .collect();
        let mut updates: Vec<(String, Value)> = Vec::new();
        let images = self.images();
        for value in &pending {
            let key = text::cmdsub(&json::jq_raw(&value.field("key")?.or(Value::str(""))));
            let mut slots = [String::new(), String::new(), String::new()];
            if text::valid_key(&key) {
                for (i, slot) in ["appIcon", "image", "preview"].iter().enumerate() {
                    let source =
                        text::cmdsub(&json::jq_raw(&value.field(slot)?.or(Value::str(""))));
                    slots[i] = images.archive(&source, &key, slot);
                }
            }
            let Value::Obj(mut object) = value.clone() else {
                return Err(Bad);
            };
            let [icon, image, preview] = slots;
            object.insert("appIcon", Value::Str(icon));
            object.insert("image", Value::Str(image));
            object.insert("preview", Value::Str(preview));
            object.insert("imageFormat", Value::int(1));
            let index = json::tostring(&object.get("key").cloned().unwrap_or(Value::Null));
            match updates.iter_mut().find(|(k, _)| *k == index) {
                Some(slot) => slot.1 = Value::Obj(object),
                None => updates.push((index, Value::Obj(object))),
            }
        }
        let (out, failed) = per_line(&data, |row| {
            let Some(value) = row else {
                return Ok(Vec::new());
            };
            let Value::Str(key) = value.field("key")? else {
                return Err(json::JqError);
            };
            Ok(vec![match updates.iter().find(|(k, _)| *k == key) {
                Some((_, update)) if update.truthy() => json::jq(update),
                _ => json::jq(&value),
            }])
        });
        if failed {
            return Err(Bad);
        }
        write_atomic(&self.archive, &joined(&out))?;
        for value in &pending {
            let key = text::cmdsub(&json::jq_raw(&value.field("key").unwrap_or(Value::Null)));
            for key in key.split('\n').filter(|k| text::valid_key(k)) {
                for slot in ["appIcon", "image", "preview"] {
                    let _ = remove_quiet(&format!("{}/{key}-{slot}", self.images));
                }
            }
        }
        Ok(())
    }

    /// An archive written before stored actions were removed still holds
    /// them: every sync clears them.
    pub fn disarm_archive(&mut self) -> Step {
        let Ok(data) = fs::read(&self.archive) else {
            return Ok(());
        };
        let armed = text::lines_text(&data).iter().any(|line| {
            ["\"exec\"", "\"execArgv\""].iter().any(|name| {
                line.match_indices(name).any(|(at, _)| {
                    line[at + name.len()..]
                        .trim_start_matches([' ', '\t', '\r', '\u{b}', '\u{c}'])
                        .starts_with(':')
                })
            })
        });
        if armed {
            self.backfill_previews();
        }
        Ok(())
    }

    pub fn prepare_archive(&mut self) -> Step {
        self.disarm_archive()?;
        self.normalize_archive()
    }

    /// Strip sender commands (keeping only an image path from them) and give
    /// entries without a picture the one their file still names. Returns how
    /// many pictures were added.
    pub fn backfill_previews(&mut self) -> usize {
        let Ok(data) = fs::read(&self.archive) else {
            return 0;
        };
        let mut out = Vec::new();
        let mut filled = 0;
        let images = self.images();
        for line in lines(&data) {
            if line.is_empty() {
                continue;
            }
            // Each jq call reads the line as a stream of values.
            let (values, _) = json::parse_stream(line);
            let raw = |f: &dyn Fn(&Value) -> json::Jq<Value>| -> String {
                let printed: String = values
                    .iter()
                    .filter_map(|v| f(v).ok())
                    .map(|v| json::jq_raw(&v) + "\n")
                    .collect();
                text::cmdsub(&printed)
            };
            let or_empty = |name: &'static str| {
                move |v: &Value| -> json::Jq<Value> { Ok(v.field(name)?.or(Value::str(""))) }
            };
            let disarmed = |v: &Value| -> Option<Value> {
                match v {
                    Value::Obj(o) => {
                        let mut o = o.clone();
                        o.remove("exec");
                        o.remove("execArgv");
                        Some(Value::Obj(o))
                    }
                    Value::Null => Some(Value::Null),
                    _ => None,
                }
            };
            let key = raw(&or_empty("key"));
            if key.is_empty() {
                out.extend(values.iter().filter_map(disarmed).map(|v| json::jq(&v)));
                continue;
            }
            // Existing file fields pass the same whole-path allowlist as new ones.
            let file = raw(&or_empty("file"));
            let mut file_src = text::preview_source(&json::jq(&Value::Arr(vec![Value::Str(file)])));
            if file_src.is_empty() {
                let exec = raw(&|v: &Value| {
                    Ok(v.field("execArgv")?.or(v.field("exec")?).or(Value::str("")))
                });
                file_src = text::preview_source(&exec);
            }
            let file_src = text::strip_file_url(&file_src).to_string();
            let mut file_action = raw(&or_empty("fileAction"));
            if file_action != "edit-screenshot" {
                file_action = text::screenshot_action(&raw(&or_empty("execArgv")), &file_src);
            }
            if file_src.is_empty() {
                file_action.clear();
            }
            let mut preview = raw(&or_empty("preview"));
            if preview.is_empty() && !file_src.is_empty() && self.previews && text::valid_key(&key)
            {
                preview = images.copy(&file_src, &key, "preview");
                if !preview.is_empty() {
                    filled += 1;
                }
            }
            for value in &values {
                let mut object = match disarmed(value) {
                    Some(Value::Obj(o)) => o,
                    Some(_) => json::Obj::default(),
                    None => continue,
                };
                object.insert("file", Value::Str(file_src.clone()));
                object.insert("fileAction", Value::Str(file_action.clone()));
                object.insert("preview", Value::Str(preview.clone()));
                out.push(json::jq(&Value::Obj(object)));
            }
        }
        let _ = write_atomic(&self.archive, &joined(&out));
        filled
    }

    /// `sync_and_prune`: catch up, then retention when a limit can have been crossed.
    pub fn sync_and_prune(&mut self) -> Step {
        self.sync_all()?;
        if self.prune_needed() {
            self.prune()?;
        }
        Ok(())
    }

    /// One source file changed (the watcher): a new row prunes only when a
    /// limit can have been crossed.
    pub fn ingest_one(&mut self, file: &str) -> Step {
        self.ingest_added = false;
        self.ingest_file(file)?;
        if self.ingest_added && self.prune_needed() {
            self.prune()?;
        }
        Ok(())
    }

    // --------------------------------------------------------- reading

    /// `list LIMIT QUERY`: newest first by timestamp (ties: later lines
    /// first), after the clear line and inside the age limit, matching the
    /// query case-insensitively against "app summary body".
    pub fn list(&self, limit: usize, query: &str) -> Step<String> {
        let cleared = if nonempty(&self.cleared_at) {
            slurp(&self.cleared_at)
                .filter(|t| text::all_digits(t))
                .map_or(0, |t| text::decimal(&t))
        } else {
            0
        };
        let cleared = Value::int(cleared);
        let cutoff = Value::int(self.cutoff());
        let needle = casefold::folded(query);
        let data = read_file(&self.archive)?;
        let mut rows: Vec<(f64, Value)> = Vec::new();
        for line in lines(&data).into_iter().rev() {
            let Some(value @ Value::Obj(_)) = row(line) else {
                continue;
            };
            let ts = value.field("timestamp")?.or(Value::int(0));
            if !(json::gt(&ts, &cleared) && json::cmp(&ts, &cutoff) != std::cmp::Ordering::Less) {
                continue;
            }
            if !query.is_empty() {
                let app = value.field("app")?.or(Value::str(""));
                let app = if app == Value::str("") {
                    "Unknown app".to_string()
                } else {
                    json::tostring(&app)
                };
                let summary = json::tostring(&value.field("summary")?.or(Value::str("")));
                let body = json::tostring(&value.field("body")?.or(Value::str("")));
                if !casefold::contains(&format!("{app} {summary} {body}"), &needle) {
                    continue;
                }
            }
            // `-(ts)`: only numbers negate.
            let Value::Num(n) = &ts else {
                return Err(Bad);
            };
            rows.push((n.f64(), value));
        }
        rows.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        let page: Vec<Value> = rows.into_iter().take(limit).map(|(_, v)| v).collect();
        Ok(json::jq(&Value::Arr(page)))
    }

    /// `unread`: archived rows newer than the seen stamp (0 when either
    /// cannot be read).
    pub fn unread(&self) -> String {
        let seen = slurp(&self.seen)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "0".into());
        let Some(seen) = json::parse(seen.as_bytes(), Dialect::Jq) else {
            return "0".into();
        };
        let Ok(data) = fs::read(&self.archive) else {
            return "0".into();
        };
        let (values, complete) = json::parse_stream(&data);
        if !complete {
            return "0".into();
        }
        let mut count = 0;
        for value in values {
            match value.field("timestamp") {
                Ok(ts) if json::gt(&ts, &seen) => count += 1,
                Ok(_) => {}
                Err(_) => return "0".into(),
            }
        }
        count.to_string()
    }

    /// `seen`: the stamp as stored, when it is one JSON value on one line.
    pub fn seen(&self) -> String {
        match slurp(&self.seen) {
            None => "0".into(),
            Some(text)
                if !text.contains('\n') && json::parse(text.as_bytes(), Dialect::Jq).is_some() =>
            {
                text
            }
            Some(_) => "0".into(),
        }
    }

    pub fn set_seen(&self, stamp: &str) -> Step {
        write_atomic(&self.seen, format!("{stamp}\n").as_bytes())
    }

    // --------------------------------------------------------- demo data

    pub fn seed_entries(&mut self, count: u64) -> Step {
        const ROWS: [(&str, &str, &str, &str, i128); 6] = [
            (
                "Files",
                "org.gnome.Nautilus",
                "Transfer complete",
                "All files were copied successfully.",
                2,
            ),
            (
                "Files",
                "org.gnome.Nautilus",
                "Download complete",
                "The archive is ready to open.",
                8,
            ),
            (
                "Files",
                "org.gnome.Nautilus",
                "Folder synchronized",
                "Everything is up to date.",
                15,
            ),
            (
                "System",
                "org.gnome.Software",
                "Update available",
                "New system updates are ready.",
                5,
            ),
            (
                "System",
                "org.gnome.Software",
                "Updates installed",
                "Your system is up to date.",
                25,
            ),
            (
                "Calendar",
                "org.gnome.Calendar",
                "Team meeting",
                "Starts in 30 minutes.",
                35,
            ),
        ];
        let mut out = String::new();
        for i in 0..count {
            let (app, icon, summary, body, minutes) = ROWS[(i % 6) as usize];
            let stamp = now_ms() - (minutes + (i / 6) as i128 * 2880) * 60_000;
            let key = format!("{stamp}-{}", 1_000_000_000u64 + i);
            let mut row = json::Obj::default();
            for (name, value) in [
                ("key", key.as_str()),
                ("app", app),
                ("appIcon", icon),
                ("summary", summary),
                ("body", body),
                ("image", ""),
                ("preview", ""),
                ("file", ""),
                ("glyph", ""),
            ] {
                row.insert(name, Value::str(value));
            }
            row.insert("urgency", Value::int(1));
            row.insert("timestamp", Value::int(stamp));
            out.push_str(&json::jq(&Value::Obj(row)));
            out.push('\n');
        }
        append(&self.archive, out.as_bytes())?;
        // The archive is read newest-first off the tail: keep it sorted.
        let (values, complete) = json::parse_stream(&read_file(&self.archive)?);
        if !complete {
            return Ok(());
        }
        let mut keyed = Vec::new();
        for value in values {
            match value.field("timestamp") {
                Ok(ts) => keyed.push((ts, value)),
                Err(_) => return Ok(()),
            }
        }
        keyed.sort_by(|a, b| json::cmp(&a.0, &b.0));
        let sorted: Vec<String> = keyed.iter().map(|(_, v)| json::jq(v)).collect();
        write_atomic(&self.archive, &joined(&sorted))
    }

    /// `seed`: demo traffic replaces the clear line and the tombstones.
    pub fn reset_for_seed(&self) {
        let _ = fs::remove_file(&self.cleared_at);
        let _ = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(OFlags::NOFOLLOW.bits() as i32)
            .open(&self.dismissed);
    }
}

/// Retention's kept rows (as lines) and dropped (key, timestamp) pairs.
type Verdict = (Vec<String>, Vec<(Value, Value)>);

/// `[.timestamp, .key]` for `max_by`.
fn key_rank(item: &(Value, Value)) -> Value {
    Value::Arr(vec![item.1.clone(), item.0.clone()])
}

/// The names `dir/*.json` matches (no hidden files; dangling symlinks skipped), sorted.
pub fn json_files(dir: &str) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.') && n.ends_with(".json"))
        .filter(|n| fs::metadata(format!("{dir}/{n}")).is_ok())
        .collect();
    names.sort();
    names
}
