//! Stock Omarchy 4.5's `live.json` / `history.json` arrays (formerly
//! `bin/read-stock-notifications.py`, reproduced byte for byte).
//!
//! The files are read-only here and never deleted: at most 8 MiB, an array of
//! at most 100 rows (`--keys` reading has no row limit). A row is used when it
//! is an object whose `key` matches `[A-Za-z0-9_-]{1,120}`, its `ts` is a
//! number in (0, 1e11) seconds, it is not `transient`, and `app`, `summary`
//! and `body` are strings. Its fingerprint (`stockHash`) is the SHA-256 of the
//! row as Python's `json.dumps(row, ensure_ascii=True, sort_keys=True)` (at
//! most 128 KiB), extended with `(st_dev, st_ino, st_size, st_mtime_ns,
//! st_ctime_ns)` of `appIcon`, `image` and the first 32 `execArgv` elements
//! that are absolute paths, or `missing`. Rows whose fingerprint the archive
//! already holds are skipped (archive lines over 128 KiB are not read). A new
//! row keeps the archived `timestamp` when it is an integer (the first
//! arrival), else `int(ts * 1000)`; a non-empty `rawBody` replaces `body`.
//! Rows come out sorted by `timestamp`, one compact ASCII JSON line each.

use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use rustix::fs::{FileType, OFlags};
use sha2::{Digest, Sha256};

use crate::json::{self, Dialect, Num, Value};

pub const LIMIT: u64 = 8 * 1024 * 1024;
pub const ROW_LIMIT: usize = 128 * 1024;

/// A failure the old reader reported (it printed only the error type).
#[derive(Debug)]
pub struct Unreadable(pub &'static str);

fn stock_key(text: &str) -> bool {
    (1..=120).contains(&text.len())
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn read_source(path: &Path) -> Result<Vec<u8>, Unreadable> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags((OFlags::NONBLOCK | OFlags::NOCTTY).bits() as i32)
        .open(path)
        .map_err(|_| Unreadable("OSError"))?;
    let stat = rustix::fs::fstat(&file).map_err(|_| Unreadable("OSError"))?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err(Unreadable("OSError"));
    }
    let mut raw = Vec::new();
    file.take(LIMIT + 1)
        .read_to_end(&mut raw)
        .map_err(|_| Unreadable("OSError"))?;
    Ok(raw)
}

/// The parsed array, or None for a blank file.
fn rows(path: &Path) -> Result<Option<Vec<Value>>, Unreadable> {
    let raw = read_source(path)?;
    if raw
        .iter()
        .all(|b| matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c))
    {
        return Ok(None);
    }
    if raw.len() as u64 > LIMIT {
        return Err(Unreadable("ValueError"));
    }
    match json::parse(&raw, Dialect::Python) {
        Some(Value::Arr(rows)) => Ok(Some(rows)),
        _ => Err(Unreadable("ValueError")),
    }
}

fn row_key(row: &Value) -> Option<&str> {
    match row {
        Value::Obj(o) => o
            .get("key")
            .and_then(Value::as_str)
            .filter(|k| stock_key(k)),
        _ => None,
    }
}

/// Every archive key a stock file still holds (`--keys`).
pub fn present_keys(path: &Path) -> Result<Vec<String>, Unreadable> {
    Ok(rows(path)?
        .unwrap_or_default()
        .iter()
        .filter_map(row_key)
        .map(|key| format!("stock-{key}"))
        .collect())
}

/// A Python number as an exact comparable integer, if it is one.
fn python_int(value: &Value) -> Option<i128> {
    match value {
        Value::Num(n) if n.is_int() => {
            Some(n.0.parse::<i128>().unwrap_or(if n.0.starts_with('-') {
                i128::MIN
            } else {
                i128::MAX
            }))
        }
        _ => None,
    }
}

/// `0 < ts < 100000000000`, then `int(ts * 1000)`.
fn arrival(ts: Option<&Value>) -> Option<i128> {
    let Some(Value::Num(n)) = ts else {
        return None;
    };
    if n.is_int() {
        let value = python_int(&Value::Num(n.clone()))?;
        (0 < value && value < 100_000_000_000).then_some(value * 1000)
    } else {
        let value = n.f64();
        (0.0 < value && value < 100_000_000_000.0).then(|| (value * 1000.0).trunc() as i128)
    }
}

fn fingerprint(row: &Value, encoded: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(encoded.as_bytes());
    let Value::Obj(object) = row else {
        unreachable!("rows are objects here");
    };
    let mut paths: Vec<Value> = vec![
        object.get("appIcon").cloned().unwrap_or(Value::Null),
        object.get("image").cloned().unwrap_or(Value::Null),
    ];
    let argv = match object.get("execArgv") {
        None => Value::Arr(Vec::new()),
        Some(Value::Str(s)) if s.starts_with('\u{feff}') => Value::Arr(Vec::new()),
        Some(Value::Str(s)) => {
            json::parse(s.as_bytes(), Dialect::Python).unwrap_or(Value::Arr(Vec::new()))
        }
        Some(other) => other.clone(),
    };
    if let Value::Arr(items) = argv {
        paths.extend(items.into_iter().take(32));
    }
    for name in paths {
        let Value::Str(name) = name else {
            continue;
        };
        let name = name.strip_prefix("file://").unwrap_or(&name);
        if !name.starts_with('/') || name.chars().count() > 4096 || name.contains('\0') {
            continue;
        }
        match std::fs::metadata(name) {
            Ok(info) => {
                let mtime = info.mtime() as i128 * 1_000_000_000 + info.mtime_nsec() as i128;
                let ctime = info.ctime() as i128 * 1_000_000_000 + info.ctime_nsec() as i128;
                digest.update(
                    format!(
                        "({}, {}, {}, {}, {})",
                        info.dev(),
                        info.ino(),
                        info.size(),
                        mtime,
                        ctime
                    )
                    .as_bytes(),
                );
            }
            Err(_) => digest.update(b"missing"),
        }
    }
    let mut out = String::with_capacity(64);
    for byte in digest.finalize() {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// The archive's (stockHash, timestamp) for each wanted key. Like the old
/// reader, an archive row whose `key` is an array or object fails the read.
fn previous(archive: &Path, wanted: &[String]) -> Result<Vec<(String, Value, Value)>, Unreadable> {
    let mut found: Vec<(String, Value, Value)> = Vec::new();
    if !archive.exists() {
        return Ok(found);
    }
    let mut data = Vec::new();
    File::open(archive)
        .and_then(|mut f| f.read_to_end(&mut data))
        .map_err(|_| Unreadable("OSError"))?;
    let mut start = 0;
    while start < data.len() {
        let end = data[start..]
            .iter()
            .position(|&b| b == b'\n')
            .map_or(data.len(), |i| start + i + 1);
        let line = &data[start..end];
        start = end;
        if line.len() > ROW_LIMIT {
            continue;
        }
        let Some(Value::Obj(old)) = json::parse(line, Dialect::Python) else {
            continue;
        };
        let key = match old.get("key") {
            Some(Value::Arr(_) | Value::Obj(_)) => return Err(Unreadable("TypeError")),
            Some(Value::Str(k)) if wanted.contains(k) => k.clone(),
            _ => continue,
        };
        let hash = old.get("stockHash").cloned().unwrap_or(Value::Null);
        let timestamp = old.get("timestamp").cloned().unwrap_or(Value::Null);
        match found.iter_mut().find(|(k, _, _)| *k == key) {
            Some(slot) => *slot = (key, hash, timestamp),
            None => found.push((key, hash, timestamp)),
        }
    }
    Ok(found)
}

/// New and changed rows of a stock array, as the archive ingests them.
pub fn changed_rows(source: &Path, archive: &Path) -> Result<Vec<String>, Unreadable> {
    let Some(rows) = rows(source)? else {
        return Ok(Vec::new());
    };
    if rows.len() > 100 {
        return Err(Unreadable("ValueError"));
    }
    let wanted: Vec<String> = rows
        .iter()
        .filter_map(row_key)
        .map(|k| format!("stock-{k}"))
        .collect();
    let previous = previous(archive, &wanted)?;
    let mut result: Vec<(i128, Value)> = Vec::new();
    for row in rows {
        let Some(raw_key) = row_key(&row).map(str::to_string) else {
            continue;
        };
        let Value::Obj(object) = &row else {
            continue;
        };
        let Some(ts) = arrival(object.get("ts")) else {
            continue;
        };
        if object.get("transient") == Some(&Value::Bool(true)) {
            continue;
        }
        if !["app", "summary", "body"]
            .iter()
            .all(|k| matches!(object.get(k), Some(Value::Str(_))))
        {
            continue;
        }
        let encoded = json::python(&row, true, false);
        if encoded.len() > ROW_LIMIT {
            continue;
        }
        let hash = fingerprint(&row, &encoded);
        let key = format!("stock-{raw_key}");
        let (old_hash, old_timestamp) = previous
            .iter()
            .find(|(k, _, _)| *k == key)
            .map_or((Value::Null, Value::Null), |(_, h, t)| {
                (h.clone(), t.clone())
            });
        if old_hash.as_str() == Some(hash.as_str()) {
            continue;
        }
        let mut out = object.clone();
        out.insert("key", Value::str(key));
        out.insert("stockHash", Value::str(hash));
        let (timestamp, order) = match python_int(&old_timestamp) {
            Some(n) => (old_timestamp, n),
            None => (Value::Num(Num::int(ts)), ts),
        };
        out.insert("timestamp", timestamp);
        if let Some(Value::Str(raw)) = out.get("rawBody").cloned()
            && !raw.is_empty()
        {
            out.insert("body", Value::Str(raw));
        }
        result.push((order, Value::Obj(out)));
    }
    result.sort_by_key(|(order, _)| *order);
    Ok(result
        .into_iter()
        .map(|(_, row)| json::python(&row, false, true))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_and_arrivals() {
        assert!(
            stock_key("n-1_A")
                && !stock_key("")
                && !stock_key("../x")
                && !stock_key(&"a".repeat(121))
        );
        let num = |t: &str| Value::Num(Num(t.into()));
        assert_eq!(arrival(Some(&num("1730000000.5"))), Some(1730000000500));
        assert_eq!(arrival(Some(&num("1730000000"))), Some(1730000000000));
        assert_eq!(arrival(Some(&num("0"))), None);
        assert_eq!(arrival(Some(&num("100000000000"))), None);
        assert_eq!(arrival(Some(&Value::Bool(true))), None);
        assert_eq!(arrival(Some(&Value::str("1"))), None);
    }
}
