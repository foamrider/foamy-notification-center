//! Small pieces of the shell semantics the store's file formats depend on:
//! `cksum`, `sha256sum`, command substitution, `dirname`/`basename`, awk's
//! field splitting and numbers, `stat -c %y` local time, and the two path
//! extractions (`grep -oiE` and jq's `test`) that decide which picture a
//! notification may open.

use std::fmt::Write as _;
use std::os::unix::fs::MetadataExt;

use sha2::{Digest, Sha256};

use crate::json::{self, Value};

/// POSIX `cksum`'s CRC of `data` (the source tag of a tombstone).
pub fn cksum(data: &[u8]) -> u32 {
    fn step(crc: u32, byte: u8) -> u32 {
        let mut c = crc ^ ((byte as u32) << 24);
        for _ in 0..8 {
            c = if c & 0x8000_0000 != 0 {
                (c << 1) ^ 0x04c1_1db7
            } else {
                c << 1
            };
        }
        c
    }
    let mut crc = data.iter().fold(0u32, |crc, &b| step(crc, b));
    let mut length = data.len() as u64;
    while length > 0 {
        crc = step(crc, (length & 0xff) as u8);
        length >>= 8;
    }
    !crc
}

pub fn sha256_hex(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    let mut out = String::with_capacity(64);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// What `$(…)` keeps of a command's output: NUL bytes dropped, trailing
/// newlines removed.
pub fn cmdsub(text: &str) -> String {
    text.replace('\0', "").trim_end_matches('\n').to_string()
}

/// `dirname`.
pub fn dirname(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() {
            ".".into()
        } else {
            "/".into()
        };
    }
    match trimmed.rfind('/') {
        None => ".".into(),
        Some(i) => {
            let parent = trimmed[..i].trim_end_matches('/');
            if parent.is_empty() {
                "/".into()
            } else {
                parent.into()
            }
        }
    }
}

/// `basename --`.
pub fn basename(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() {
            String::new()
        } else {
            "/".into()
        };
    }
    trimmed.rsplit('/').next().unwrap_or("").to_string()
}

/// A file's lines (awk records, grep lines): the last one also without its
/// newline, invalid UTF-8 replaced.
pub fn lines_text(data: &[u8]) -> Vec<String> {
    let mut out: Vec<String> = data
        .split(|&b| b == b'\n')
        .map(|l| String::from_utf8_lossy(l).into_owned())
        .collect();
    if out.last().is_some_and(String::is_empty) {
        out.pop();
    }
    out
}

/// awk's default field splitting (blanks and newlines).
pub fn fields(line: &str) -> Vec<&str> {
    line.split([' ', '\t', '\n'])
        .filter(|f| !f.is_empty())
        .collect()
}

/// awk's numeric value of a string: its longest numeric prefix, else 0.
pub fn awk_number(text: &str) -> f64 {
    let t = text.trim_start_matches([' ', '\t', '\n']);
    let b = t.as_bytes();
    let mut end = 0;
    let mut i = 0;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    let mut digits = false;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
        digits = true;
    }
    if i < b.len() && b[i] == b'.' {
        i += 1;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
            digits = true;
        }
    }
    if digits {
        end = i;
        if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
            let mut j = i + 1;
            if j < b.len() && (b[j] == b'+' || b[j] == b'-') {
                j += 1;
            }
            let start = j;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            if j > start {
                end = j;
            }
        }
    }
    t[..end].parse().unwrap_or(0.0)
}

/// Whether awk treats a field as a number in comparisons (a "strnum").
pub fn awk_numeric(text: &str) -> bool {
    let t = text.trim_matches([' ', '\t', '\n']);
    let n = t.strip_prefix(['+', '-']).unwrap_or(t);
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let (mantissa, exponent) = match n.find(['e', 'E']) {
        Some(i) => (&n[..i], Some(&n[i + 1..])),
        None => (n, None),
    };
    let mantissa_ok = match mantissa.split_once('.') {
        Some((a, b)) => {
            (a.is_empty() || digits(a))
                && (b.is_empty() || digits(b))
                && !(a.is_empty() && b.is_empty())
        }
        None => digits(mantissa),
    };
    let exponent_ok = exponent.is_none_or(|e| digits(e.strip_prefix(['+', '-']).unwrap_or(e)));
    mantissa_ok && exponent_ok
}

/// awk's `a == b` between two fields/variables.
pub fn awk_equal(a: &str, b: &str) -> bool {
    if awk_numeric(a) && awk_numeric(b) {
        awk_number(a) == awk_number(b)
    } else {
        a == b
    }
}

/// A decimal digit string as a number, saturating (Bash arithmetic on the
/// timestamps and counts the store keeps).
pub fn decimal(text: &str) -> i128 {
    text.bytes().fold(0i128, |n, b| {
        n.saturating_mul(10).saturating_add((b - b'0') as i128)
    })
}

pub fn all_digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())
}

/// `^[0-9]+-[0-9]+$`: a Foamy / stock 4.0 key with its arrival stamp.
pub fn ts_id(key: &str) -> bool {
    key.split_once('-')
        .is_some_and(|(a, b)| all_digits(a) && all_digits(b))
}

/// `^([0-9]+-[0-9]+|stock-[A-Za-z0-9_-]{1,120})$`.
pub fn valid_key(key: &str) -> bool {
    ts_id(key)
        || key.strip_prefix("stock-").is_some_and(|rest| {
            (1..=120).contains(&rest.len())
                && rest
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
}

/// The stamp of a ts-id key.
pub fn key_stamp(key: &str) -> Option<&str> {
    ts_id(key)
        .then(|| key.split_once('-').map(|(a, _)| a))
        .flatten()
}

/// `file:///*|/*`: a sender file rather than a theme icon name.
pub fn is_path(text: &str) -> bool {
    text.starts_with("file:///") || text.starts_with('/')
}

/// `${text#file://}`.
pub fn strip_file_url(text: &str) -> &str {
    text.strip_prefix("file://").unwrap_or(text)
}

/// `^[[:alnum:]_.-]+$` (C locale): a theme icon name.
pub fn theme_name(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}

const EXTENSIONS: [&str; 5] = ["jpg", "jpeg", "png", "webp", "gif"];

fn ends_with_extension(text: &[u8]) -> Option<usize> {
    // The length of the `.ext` suffix (ASCII case-insensitive), if any.
    EXTENSIONS.iter().find_map(|ext| {
        let n = ext.len() + 1;
        (text.len() >= n
            && text[text.len() - n] == b'.'
            && text[text.len() - ext.len()..].eq_ignore_ascii_case(ext.as_bytes()))
        .then_some(n)
    })
}

/// jq `test("^(file://)?/[^\"'\r\n]*\.(jpe?g|png|webp|gif)$"; "i")`, where
/// `$` also matches before a final newline.
pub fn preview_path(text: &str) -> bool {
    let body = text.strip_suffix('\n').unwrap_or(text).as_bytes();
    let rest = if body.len() >= 7 && body[..7].eq_ignore_ascii_case(b"file://") {
        &body[7..]
    } else {
        body
    };
    if rest.first() != Some(&b'/')
        || rest[1..]
            .iter()
            .any(|b| matches!(b, b'"' | b'\'' | b'\r' | b'\n'))
    {
        return false;
    }
    ends_with_extension(rest).is_some_and(|n| rest.len() > n)
}

/// `grep -oiE "(file://)?/[^\"' ]*\.(jpe?g|png|webp|gif)" | head -n 1`:
/// the leftmost-longest match on the first line that has one.
fn grep_preview(text: &str) -> String {
    for line in text.split('\n') {
        let b = line.as_bytes();
        for start in 0..b.len() {
            let slash = if b[start] == b'/' {
                start
            } else if b.len() >= start + 8
                && b[start..start + 7].eq_ignore_ascii_case(b"file://")
                && b[start + 7] == b'/'
            {
                start + 7
            } else {
                continue;
            };
            let mut run = slash + 1;
            while run < b.len() && !matches!(b[run], b'"' | b'\'' | b' ') {
                run += 1;
            }
            // Longest: the last end within the run that closes on an extension.
            if let Some(end) = (slash + 2..=run)
                .rev()
                .find(|&end| ends_with_extension(&b[slash + 1..end]).is_some())
            {
                return line[start..end].to_string();
            }
        }
    }
    String::new()
}

/// `preview_source`: the first absolute image path a notification action
/// names (an argv vector, JSON-encoded, or a legacy shell string). Not yet
/// stripped of `file://`.
pub fn preview_source(action: &str) -> String {
    if action.starts_with('[') {
        let (values, _) = json::parse_stream(action.as_bytes());
        for value in values {
            if let Value::Arr(items) = value {
                for item in items {
                    if let Value::Str(s) = item
                        && preview_path(&s)
                    {
                        // `head -n 1` of jq's raw output.
                        return s.split('\n').next().unwrap_or("").to_string();
                    }
                }
            }
        }
        return String::new();
    }
    grep_preview(action)
}

/// `screenshot_action`: "edit-screenshot" for the standard two-argument
/// Omasnap / Tensaku vector that names `file`, else "" (one line per JSON
/// value in `action`, as jq printed them).
pub fn screenshot_action(action: &str, file: &str) -> String {
    let (values, _) = json::parse_stream(action.as_bytes());
    let editors = [
        "tensaku-edit",
        "/usr/bin/tensaku-edit",
        "omasnap",
        "/usr/bin/omasnap",
    ];
    let lines: Vec<&str> = values
        .iter()
        .map(|value| match value {
            Value::Arr(items) if items.len() == 2 => {
                let editor = matches!(&items[0], Value::Str(s) if editors.contains(&s.as_str()));
                let named = matches!(&items[1], Value::Str(s) if s.strip_prefix("file://").unwrap_or(s) == file);
                if editor && named && !file.is_empty() { "edit-screenshot" } else { "" }
            }
            _ => "",
        })
        .collect();
    cmdsub(&lines.join("\n"))
}

/// `stat -c %y`-style local time: `2026-11-06 16:41:23.123456789 +0100`.
fn local_time(seconds: i64, nanos: i64) -> String {
    // `time_t` is 64-bit on both targets; libc marks it deprecated for musl's
    // 32-bit time64 transition, which does not apply here.
    #[allow(deprecated)]
    let time = seconds as libc::time_t;
    // SAFETY: an all-zero `tm` is a valid value of this plain C struct.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers refer to live, properly aligned locals.
    let converted = unsafe { libc::localtime_r(&time, &mut tm) };
    if converted.is_null() {
        return format!("{seconds}.{nanos:09}");
    }
    let offset = tm.tm_gmtoff;
    let (sign, offset) = if offset < 0 {
        ('-', -offset)
    } else {
        ('+', offset)
    };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:09} {}{:02}{:02}",
        tm.tm_year as i64 + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        nanos,
        sign,
        offset / 3600,
        (offset % 3600) / 60
    )
}

/// `stat -Lc '%d:%i:%s:%y:%z'` of a path, with its newline, or None.
pub fn stat_line(path: &str) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    Some(format!(
        "{}:{}:{}:{}:{}\n",
        meta.dev(),
        meta.ino(),
        meta.size(),
        local_time(meta.mtime(), meta.mtime_nsec()),
        local_time(meta.ctime(), meta.ctime_nsec())
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cksum_matches_coreutils() {
        assert_eq!(cksum(b"/home/x"), 2664454222);
        assert_eq!(cksum(b""), 4294967295);
    }

    #[test]
    fn shell_helpers() {
        assert_eq!(cmdsub("a\0b\n\n"), "ab");
        for (path, dir, base) in [
            ("/a/b", "/a", "b"),
            ("/a/b/", "/a", "b"),
            ("a", ".", "a"),
            ("/", "/", "/"),
            ("", ".", ""),
            ("/a", "/", "a"),
        ] {
            assert_eq!(dirname(path), dir, "{path}");
            assert_eq!(basename(path), base, "{path}");
        }
        assert_eq!(fields("  a b\tc "), ["a", "b", "c"]);
        assert_eq!(awk_number("12abc"), 12.0);
        assert_eq!(awk_number(""), 0.0);
        assert!(awk_equal("0123", "123") && !awk_equal("x", "123"));
        assert!(
            valid_key("1-2")
                && valid_key("stock-a_B-9")
                && !valid_key("stock-")
                && !valid_key("../x")
                && !valid_key("1-")
        );
        assert!(!valid_key(&format!("stock-{}", "a".repeat(121))));
    }

    #[test]
    fn preview_paths_follow_the_old_patterns() {
        assert!(
            preview_path("/a.png")
                && preview_path("FILE:///a.PNG")
                && preview_path("/a b.JpEg")
                && preview_path("/.png")
        );
        assert!(
            preview_path("/a.png\n") && !preview_path("x\n/a.png") && !preview_path("/a.png\r")
        );
        assert!(
            !preview_path("/a.png.desktop")
                && !preview_path("relative.png")
                && !preview_path("/a\".png")
        );
        assert_eq!(
            preview_source(r#"["viewer","file:///tmp/x.gif"]"#),
            "file:///tmp/x.gif"
        );
        assert_eq!(preview_source(r#"["/a.png"] garbage"#), "/a.png");
        assert_eq!(
            preview_source("viewer /tmp/legacy.gif now"),
            "/tmp/legacy.gif"
        );
        assert_eq!(preview_source("x/a.png/b.png y"), "/a.png/b.png");
        assert_eq!(preview_source("open file://x/a.png"), "//x/a.png");
        assert_eq!(preview_source("a FILE:///x.GIF"), "FILE:///x.GIF");
        assert_eq!(preview_source("a\nb /c.JPG"), "/c.JPG");
        assert_eq!(preview_source("no image"), "");
        assert_eq!(
            screenshot_action(r#"["omasnap","file:///s.png"]"#, "/s.png"),
            "edit-screenshot"
        );
        assert_eq!(
            screenshot_action(r#"["omasnap","/s.png","x"]"#, "/s.png"),
            ""
        );
        assert_eq!(
            screenshot_action(r#"["omasnap","/s.png"] ["omasnap","/s.png"]"#, "/s.png"),
            "edit-screenshot\nedit-screenshot"
        );
        assert_eq!(screenshot_action("bad", "/s.png"), "");
    }
}
