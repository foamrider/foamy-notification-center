//! Copying source notifications into the archive (`sync`, and the watcher's
//! per-file updates). One function per function of the old script.

use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use rustix::fs::{FileType, OFlags};

use crate::json::{self, Value};
use crate::stock;
use crate::store::{self, Bad, Step, Store};
use crate::text;

/// Largest source file (and stock row) the archive takes.
pub const MAX_SOURCE_BYTES: usize = 131_072;

/// The first `limit` bytes of a regular file (symlinks followed, as `head`
/// did; a FIFO or device is refused rather than read).
pub fn read_regular(path: &str, limit: u64) -> Option<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags((OFlags::NONBLOCK | OFlags::NOCTTY).bits() as i32)
        .open(path)
        .ok()?;
    let stat = rustix::fs::fstat(&file).ok()?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return None;
    }
    let mut data = Vec::new();
    file.take(limit).read_to_end(&mut data).ok()?;
    Some(data)
}

/// `$(…)` on bytes: NULs dropped, trailing newlines removed.
fn cmdsub_bytes(data: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = data.iter().copied().filter(|&b| b != 0).collect();
    while out.last() == Some(&b'\n') {
        out.pop();
    }
    out
}

/// A value as jq's `@sh` put it into the shell (and `eval` took it back),
/// or None where `@sh` refuses it.
fn shell_word(value: &Value) -> Option<String> {
    match value {
        Value::Str(s) => Some(s.replace('\0', "")),
        Value::Num(n) => Some(n.jq()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Null => Some("null".into()),
        Value::Arr(_) | Value::Obj(_) => None,
    }
}

/// The first archive line holding `"key":"KEY"` (grep -F).
fn existing_line(archive: &str, key: &str) -> Option<Vec<u8>> {
    let data = fs::read(archive).ok()?;
    let needle = format!("\"key\":\"{key}\"");
    data.split(|&b| b == b'\n')
        .find(|line| line.windows(needle.len()).any(|w| w == needle.as_bytes()))
        .map(<[u8]>::to_vec)
}

impl Store {
    /// Everything the source holds, history first, then live popups; then
    /// Foamy's handled journal and the tombstones it no longer needs.
    pub fn sync_all(&mut self) -> Step {
        for dir in [self.src_history.clone(), self.src_dir.clone()] {
            for name in store::json_files(&dir) {
                self.ingest_file(&format!("{dir}/{name}"))?;
            }
        }
        let _ = self.apply_handled();
        self.trim_absent_tombstones();
        Ok(())
    }

    pub fn ingest_file(&mut self, file: &str) -> Step {
        let name = text::basename(file);
        let key = name.strip_suffix(".json").unwrap_or(&name).to_string();
        if key == "live" || key == "history" {
            if self.source_kind != "stock" {
                return Ok(());
            }
            return self.ingest_array(file);
        }
        if !text::ts_id(&key) || !store::nonempty(file) {
            return Ok(());
        }
        let source = read_regular(file, MAX_SOURCE_BYTES as u64 + 1).ok_or(Bad)?;
        let source = cmdsub_bytes(&source);
        if source.len() > MAX_SOURCE_BYTES {
            return Ok(());
        }
        self.ingest_json(&key, &source)
    }

    /// Stock 4.5 arrays: only changed rows, under their opaque `stock-` keys.
    fn ingest_array(&mut self, file: &str) -> Step {
        if !store::nonempty(file) {
            return Ok(());
        }
        let rows =
            stock::changed_rows(Path::new(file), Path::new(&self.archive)).map_err(|error| {
                eprintln!(
                    "notification-center: cannot read stock notification array ({})",
                    error.0
                );
                Bad
            })?;
        for row in rows {
            if row.len() > MAX_SOURCE_BYTES {
                continue;
            }
            let key = json::parse(row.as_bytes(), json::Dialect::Jq)
                .and_then(|v| v.field("key").ok())
                .map(|k| text::cmdsub(&json::jq_raw(&k)))
                .unwrap_or_default();
            self.ingest_json(&key, row.as_bytes())?;
        }
        Ok(())
    }

    /// Archive new or changed source content; unchanged content is no work.
    pub fn ingest_json(&mut self, key: &str, source: &[u8]) -> Step {
        if self.is_dismissed(key) {
            return Ok(());
        }
        // A file caught mid-write, whitespace or several values: caught again
        // later. jq skipped values it could not read fields from (only the
        // last one failing failed the step) and needed exactly one.
        let (values, complete) = json::parse_stream(source);
        let readable = |v: &Value| matches!(v, Value::Obj(_) | Value::Null);
        if !complete || values.last().is_some_and(|v| !readable(v)) {
            return Ok(());
        }
        let mut values: Vec<Value> = values.into_iter().filter(readable).collect();
        if values.len() != 1 {
            return Ok(());
        }
        let mut value = values.remove(0);
        let field = |v: &Value, name: &str| v.field(name).unwrap_or(Value::Null);
        // Transient action feedback stays a toast.
        if field(&value, "transient") == Value::Bool(true) {
            return Ok(());
        }
        let file_stamp = match field(&value, "timestamp").or(Value::int(0)) {
            Value::Num(n) => n.jq(),
            Value::Str(s) => json::tonumber(&s).map_or_else(|_| "0".into(), |n| n.jq()),
            _ => "0".into(),
        };
        let word = |v: Value| json::tostring(&v).replace('\0', "");
        let app_icon = word(field(&value, "appIcon").or(Value::str("")));
        let image_src = word(field(&value, "image").or(Value::str("")));
        let exec_src = match field(&value, "execArgv")
            .or(field(&value, "exec"))
            .or(Value::str(""))
        {
            Value::Str(s) => s.replace('\0', ""),
            other => json::jq(&other).replace('\0', ""),
        };

        let existing = existing_line(&self.archive, key);
        // I2: a row in the archive always takes its update. I1 for absent keys.
        if existing.is_none() {
            if self.stamp_excluded(key) {
                return Ok(());
            }
            // Foamy handled it before its file reached us.
            if self.handled_listed(key) {
                self.add_tombstones(&[format!("{key} {}", text::key_stamp(key).unwrap_or(""))])?;
                return Ok(());
            }
            if key.starts_with("stock-") && text::all_digits(&file_stamp) {
                let stamp = text::decimal(&file_stamp);
                if stamp > 0 && (stamp <= self.cleared_line() || stamp < self.cutoff()) {
                    return Ok(());
                }
            }
        }

        let mut file_src = String::new();
        let mut file_action = String::new();
        if !exec_src.is_empty() {
            file_src = text::strip_file_url(&text::preview_source(&exec_src)).to_string();
            if !file_src.is_empty() {
                file_action = text::screenshot_action(&exec_src, &file_src);
            }
        }
        // An in-place stock update changes ts; keep the first arrival for unread state.
        let mut source = source.to_vec();
        if let (true, Some(line)) = (key.starts_with("stock-"), &existing) {
            let (rows, _) = json::parse_stream(line);
            let stamps: Vec<Value> = rows
                .iter()
                .filter_map(|r| r.field("timestamp").ok())
                .collect();
            let [stamp] = stamps.as_slice() else {
                return Err(Bad);
            };
            value = match value {
                Value::Obj(mut o) => {
                    o.insert("timestamp", stamp.clone());
                    Value::Obj(o)
                }
                _ => {
                    let mut o = json::Obj::default();
                    o.insert("timestamp", stamp.clone());
                    Value::Obj(o)
                }
            };
            source = json::jq(&value).into_bytes();
        }
        let sources = format!(
            "{app_icon}\n{image_src}\n{file_src}\n{}\n",
            self.previews_raw
        );
        let source_hash = text::sha256_hex(&source);
        let sources_hash = text::sha256_hex(sources.as_bytes());
        let mut assets = sources.clone();
        for asset in [&app_icon, &image_src, &file_src] {
            if text::is_path(asset)
                && let Some(line) = text::stat_line(text::strip_file_url(asset))
            {
                assets.push_str(&line);
            }
        }
        let assets_hash = text::sha256_hex(assets.as_bytes());

        let mut ex = [const { String::new() }; 8];
        let mut ex_format = "0".to_string();
        if let Some(line) = &existing {
            let (rows, complete) = json::parse_stream(line);
            if !complete {
                return Err(Bad);
            }
            let words: Vec<Option<Vec<String>>> = rows
                .iter()
                .map(|row| {
                    let take =
                        |name: &str, default: Value| row.field(name).ok().map(|v| v.or(default));
                    let mut fields = vec![
                        take("fileAction", Value::str(""))?,
                        Value::Str(json::tostring(&take("imageFormat", Value::int(0))?)),
                    ];
                    for name in [
                        "sourceHash",
                        "assetsHash",
                        "appIcon",
                        "image",
                        "preview",
                        "assetSources",
                    ] {
                        fields.push(take(name, Value::str(""))?);
                    }
                    fields.iter().map(shell_word).collect()
                })
                .collect();
            if words.last().is_some_and(Option::is_none) {
                return Err(Bad);
            }
            let words: Vec<Vec<String>> = words.into_iter().flatten().collect();
            let [only] = words.as_slice() else {
                return Ok(());
            };
            ex = std::array::from_fn(|i| only[i].clone());
            ex_format = ex[1].clone();
            let [action, _, source, asset, ..] = &ex;
            if *action == file_action
                && ex_format == "1"
                && *source == source_hash
                && *asset == assets_hash
            {
                return Ok(());
            }
        }
        let [
            _,
            _,
            _,
            ex_assets,
            ex_icon,
            ex_image,
            ex_preview,
            ex_sources,
        ] = &ex;
        let images = self.images();
        let (icon_copy, image_copy, preview_copy) =
            if existing.is_some() && ex_format == "1" && *ex_assets == assets_hash {
                (ex_icon.clone(), ex_image.clone(), ex_preview.clone())
            } else {
                let mut icon = images.archive(&app_icon, key, "appIcon");
                let mut image = images.archive(&image_src, key, "image");
                let mut preview = String::new();
                if self.previews && !file_src.is_empty() {
                    preview = images.copy(&file_src, key, "preview");
                }
                // Sender cleanup is not an image change: keep copies when the same original disappears.
                if existing.is_some() && ex_format == "1" && *ex_sources == sources_hash {
                    let gone = |path: &str| fs::metadata(path).is_err();
                    if text::is_path(&app_icon) && gone(text::strip_file_url(&app_icon)) {
                        icon = ex_icon.clone();
                    }
                    if text::is_path(&image_src) && gone(text::strip_file_url(&image_src)) {
                        image = ex_image.clone();
                    }
                    if !file_src.is_empty() && gone(&file_src) {
                        preview = ex_preview.clone();
                    }
                }
                (icon, image, preview)
            };

        let mut entry = json::Obj::default();
        entry.insert("key", Value::str(key));
        entry.insert("imageFormat", Value::int(1));
        entry.insert("sourceHash", Value::Str(source_hash));
        entry.insert("stockHash", field(&value, "stockHash").or(Value::str("")));
        entry.insert("assetsHash", Value::Str(assets_hash));
        entry.insert("assetSources", Value::Str(sources_hash));
        entry.insert(
            "desktopEntry",
            field(&value, "desktopEntry").or(Value::str("")),
        );
        entry.insert("app", field(&value, "app").or(Value::str("")));
        entry.insert("appIcon", Value::Str(icon_copy));
        entry.insert("summary", field(&value, "summary").or(Value::str("")));
        entry.insert("body", field(&value, "body").or(Value::str("")));
        entry.insert("image", Value::Str(image_copy));
        entry.insert("preview", Value::Str(preview_copy));
        entry.insert("file", Value::Str(file_src));
        entry.insert("fileAction", Value::Str(file_action));
        entry.insert("glyph", field(&value, "glyph").or(Value::str("")));
        entry.insert("urgency", field(&value, "urgency").or(Value::int(1)));
        let timestamp = field(&value, "timestamp").or(Value::int(0));
        let timestamp = if json::gt(&timestamp, &Value::int(0)) {
            timestamp
        } else {
            let stamp = key.split('-').next().unwrap_or("");
            json::tonumber(stamp).map_or(Value::int(0), Value::Num)
        };
        entry.insert("timestamp", timestamp);
        let entry = json::jq(&Value::Obj(entry));

        if existing.is_some() {
            // A progress update is the same unread notification, not a new arrival.
            let data = fs::read(&self.archive).map_err(|_| Bad)?;
            let (out, failed) = store::per_line(&data, |row| {
                let Some(row) = row else {
                    return Ok(Vec::new());
                };
                Ok(vec![if row.field("key")? == Value::str(key) {
                    entry.clone()
                } else {
                    json::jq(&row)
                }])
            });
            if failed {
                return Err(Bad);
            }
            let mut bytes = Vec::new();
            for line in out {
                bytes.extend_from_slice(line.as_bytes());
                bytes.push(b'\n');
            }
            foamy_helper::fs::write_atomic(Path::new(&self.archive), &bytes, 0o600).map_err(
                |error| {
                    eprintln!("notification-center: {error}");
                    Bad
                },
            )?;
        } else {
            crate::store::append_line(&self.archive, &entry)?;
            self.ingest_added = true;
        }
        self.entry(&entry);
        Ok(())
    }
}
