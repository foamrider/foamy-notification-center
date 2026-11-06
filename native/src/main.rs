//! `foamy-notification-center-helper`: the store behind the notification
//! center (formerly `bin/notification-center`, `bin/read-stock-notifications.py`
//! and `bin/browser-favicon.py`).
//!
//! Stock 4.5 writes `live.json`/`history.json` arrays; Foamy and stock 4.0
//! write one file per notification. New and changed entries are copied into
//! the center's own archive, with their images retained independently of the
//! daemon's limits. Source files are only read, never written or deleted.
//!
//! # Contract
//!
//! Every subcommand prints JSON (one object or one array, one line),
//! including failures: `{"ok":false,"error":"<message>"}`, exit 1. An
//! unknown subcommand prints the usage on standard error and exits 64.
//! Everything is created with umask 077.
//!
//! - `sync` → `{"ok":true,"synced":true}`; errors "cannot normalize
//!   notification archive", "cannot synchronize notification history"
//! - `list [LIMIT] [QUERY]` → the archive as one array, newest first by
//!   `timestamp` (ties: later archive lines first), at most LIMIT (default
//!   200) rows newer than the clear line and inside the age limit; QUERY (at
//!   most 256 characters) matches "app summary body" (an empty app reads
//!   "Unknown app") literally and case-insensitively with Unicode full case
//!   folding. Errors "list limit must be a nonnegative integer", "search is
//!   too long", "cannot normalize notification archive", "cannot read
//!   notification archive"
//! - `remove KEY…` (keys `^([0-9]+-[0-9]+|stock-[A-Za-z0-9_-]{1,120})$`) →
//!   `{"ok":true,"removed":"<first key>","count":N}`; errors "remove needs a
//!   key", "invalid notification key", "could not remove notifications"
//! - `clear [MS]` (at most 16 digits; default now, never later) →
//!   `{"ok":true,"cleared":true}`; error "clear cutoff must be a millisecond
//!   timestamp"
//! - `seen [STAMP]` → `{"ok":true,"seen":<stamp>}` (reads, or writes
//!   `STAMP\n`); `unread` → `{"ok":true,"unread":N}`
//! - `seed [N]` → `{"ok":true,"seeded":N}`; `backfill` →
//!   `{"ok":true,"filled":N}`; `prune` → `{"ok":true,"pruned":true}`
//! - `watch` → archived rows (each the row's own line) and events, one per
//!   line: `{"event":"storeChanged"}`, `{"event":"dndChanged"}`,
//!   `{"event":"seenChanged"}`, `{"event":"pruned","keys":[…]}` (Foamy keys
//!   dropped by retention, at most 1,000 per event, not for stock),
//!   `{"event":"rewatch"}` (a missing source directory appeared; exit 0).
//!   It runs `LC_ALL=C inotifywait -m -e close_write -e moved_to -e delete
//!   -e create -e delete_self -e move_self --format '%e|%w%f' <paths>` on the
//!   store, the source, history, state and handled directories (missing
//!   ones through their nearest existing ancestor), killed with the watcher
//!   (`PR_SET_PDEATHSIG`). It syncs once watches are established, then
//!   blocks on those events; retention runs every `NC_RETENTION_INTERVAL`
//!   seconds of wall clock (default 3600) however busy the stream is. Ends
//!   with "notification source changed; reconnecting" (a watched directory
//!   went away), "notification watcher stopped", "inotifywait is not
//!   installed", "notification watcher failed to start" or a sync error.
//! - `favicon` → `foamy_helper::favicon::run()`: a `{"browser","hostname"}`
//!   request on standard input, `{"source":…,"status":…}` (browser-favicon.py's
//!   contract; local Chromium caches only, never a web request).
//!
//! Environment: `NC_SOURCE` (stock|foamy|legacy, default stock),
//! `NC_SRC_DIR` (default `$HOME/.local/state/omarchy/notifications`, HOME
//! even with a custom XDG_STATE_HOME), `NC_SRC_HISTORY` (default
//! `$NC_SRC_DIR/history`), `NC_HANDLED` (Foamy's handled journal, read-only),
//! `NC_STATE_FILE` (DND state; default the stock `notifications.json` and
//! `quiet.json`), `NC_KEEP_DAYS` (30), `NC_MAX_ITEMS` (1000), `NC_PREVIEWS`
//! (1), and test-only `NC_STORE` (default
//! `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-notification-center`) and
//! `NC_RETENTION_INTERVAL`. Non-integer limits fall back to their defaults.
//!
//! Files under the store (0700; files 0600, written by atomic rename except
//! appends): `archive.jsonl` (one row per line: key, imageFormat 1,
//! sourceHash, stockHash, assetsHash, assetSources, desktopEntry, app,
//! appIcon, summary, body, image, preview, file, fileAction, glyph, urgency,
//! timestamp, in that order, numbers as written), `images/` (normalized PNG
//! copies), `dismissed` (tombstones "KEY TS REMOVED_AT SOURCE", SOURCE the
//! POSIX `cksum` of the source directory), `cleared_at` ("MS"; only rises),
//! `pruned_through` ("TS KEY"; only rises), `seen`, and `lock` (`flock`, held
//! for each archive step). Hashes: `sourceHash` is the SHA-256 of the source
//! file (trailing newlines removed) or stock row, `assetSources` of
//! "appIcon\nimage\nfile\nNC_PREVIEWS\n", `assetsHash` of that plus `stat -L
//! -c '%d:%i:%s:%y:%z'` of each sender path. Bounds: source files 128 KiB,
//! stock arrays 8 MiB and 100 rows (rows 128 KiB), the handled journal's
//! first 64 KiB, sender images 5 MiB (see `images`).
//!
//! # Archive invariants
//!
//! Identity is the key, never the timestamp. "ts-id" keys (Foamy, stock 4.0
//! files) carry an immutable arrival stamp; "stock-…" keys (stock 4.5 arrays)
//! do not, and their source rows change ts on in-place updates. A row's rank
//! is (archive timestamp, key), keys compared bytewise.
//!
//! - I1 Removed stays removed: a key that left the archive (dismissed,
//!   handled, cleared or pruned) is never ingested again while a source still
//!   holds a copy.
//! - I2 Present rows update: exclusions apply only to keys absent from the
//!   archive.
//! - I3 Retention keeps the top `max_items` rows by rank among rows younger
//!   than `keep_days`; the watermark records the highest rank it dropped.
//! - I4 New keys enter: a key never removed, younger than `keep_days`, after
//!   the clear line and ranked above the watermark is archived on the next sync.
//!
//! For keys absent from the archive, I1 holds for ts-id keys by a durable
//! exclusion of their stamp (at or below `cleared_at`, or ranked at or below
//! the watermark), else by a tombstone; the age limit is not durable (it can
//! be raised). Stock keys rely on tombstones only, so every removal of one
//! writes a tombstone. Durable exclusions only widen. A tombstone is dropped
//! when a durable exclusion covers its ts-id key, or when a full sync of the
//! source it was written under finds the key in no source file an hour or
//! more after its removal.

mod casefold;
mod images;
mod ingest;
mod json;
mod stock;
mod store;
mod text;
mod watch;

use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;

use store::{Store, print_line};

const USAGE: &str = "notification-center: the store behind the Omarchy notification center

  watch              follow the notification service and archive what it receives
  sync               catch up on anything not archived yet
  list [LIMIT] [Q]   the archive as JSON, newest first (default 200), optionally matching Q
  remove KEY...      drop the specified notifications
  clear [MS]         delete all of them up to MS (default now), and their images
  seen [MS]          read or set when the center was last opened
  unread             how many arrived since then
  seed [N]           fill the archive with test traffic
  backfill           give older entries the picture their action points at
  prune              apply the retention limits now
  favicon            look up a website's cached favicon (JSON request on stdin)
";

/// Prints `{"ok":false,"error":…}` and exits 1 (the old `die`).
pub fn fail(message: &str) -> ! {
    print_line(&format!(
        "{{\"ok\":false,\"error\":{}}}",
        json::jq_str(message)
    ));
    std::process::exit(1)
}

/// `cmd_sync`: migrate the archive, then catch up and apply retention.
pub fn sync(store: &mut Store) -> Result<(), String> {
    store.ensure()?;
    store
        .locked(Store::prepare_archive)
        .map_err(|_| "cannot normalize notification archive".to_string())?;
    store
        .locked(Store::sync_and_prune)
        .map_err(|_| "cannot synchronize notification history".to_string())
}

fn or_fail<T>(result: Result<T, String>) -> T {
    result.unwrap_or_else(|message| fail(&message))
}

/// The plugin's `bin/` (the helper lives in `bin/<arch>/`), where `policy.xml` is.
fn policy_dir() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|exe| {
            exe.parent()
                .and_then(|arch| arch.parent())
                .map(PathBuf::from)
        })
        .map(|dir| dir.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn run(args: Vec<String>) -> ExitCode {
    let command = args.first().map(String::as_str).unwrap_or("");
    let arg = |i: usize| args.get(i).map(String::as_str).filter(|a| !a.is_empty());
    let mut store = Store::from_env(policy_dir());
    match command {
        "sync" => {
            store.quiet = true;
            or_fail(sync(&mut store));
            print_line(r#"{"ok":true,"synced":true}"#);
        }
        "watch" => watch::run(&mut store),
        "list" => {
            or_fail(store.ensure());
            if store.locked(Store::normalize_archive).is_err() {
                fail("cannot normalize notification archive");
            }
            let limit = arg(1).unwrap_or("200");
            let query = arg(2).unwrap_or("");
            if !text::all_digits(limit) {
                fail("list limit must be a nonnegative integer");
            }
            if query.chars().count() > 256 {
                fail("search is too long");
            }
            let limit = usize::try_from(text::decimal(limit)).unwrap_or(usize::MAX);
            match store.list(limit, query) {
                Ok(page) => print_line(&page),
                Err(_) => fail("cannot read notification archive"),
            }
        }
        "remove" => {
            or_fail(store.ensure());
            let keys = &args[1..];
            if keys.is_empty() {
                fail("remove needs a key");
            }
            if !keys.iter().all(|k| text::valid_key(k)) {
                fail("invalid notification key");
            }
            if store.locked(|s| s.remove_keys(keys)).is_err() {
                fail("could not remove notifications");
            }
            print_line(&format!(
                "{{\"ok\":true,\"removed\":{},\"count\":{}}}",
                json::jq_str(&keys[0]),
                keys.len()
            ));
        }
        "clear" => {
            or_fail(store.ensure());
            let cut = arg(1);
            if cut.is_some_and(|c| c.len() > 16 || !text::all_digits(c)) {
                fail("clear cutoff must be a millisecond timestamp");
            }
            let _ = store.locked(|s| s.clear_all(cut));
            print_line(r#"{"ok":true,"cleared":true}"#);
        }
        "seen" => {
            or_fail(store.ensure());
            match arg(1) {
                Some(stamp) => {
                    if stamp.contains('\n')
                        || json::parse(stamp.as_bytes(), json::Dialect::Jq).is_none()
                    {
                        fail("seen must be a millisecond timestamp");
                    }
                    let _ = store.set_seen(stamp);
                    print_line(&format!("{{\"ok\":true,\"seen\":{stamp}}}"));
                }
                None => print_line(&format!("{{\"ok\":true,\"seen\":{}}}", store.seen())),
            }
        }
        "unread" => {
            or_fail(store.ensure());
            print_line(&format!("{{\"ok\":true,\"unread\":{}}}", store.unread()));
        }
        "seed" => {
            or_fail(store.ensure());
            let count = arg(1).unwrap_or("25");
            if !text::all_digits(count) {
                fail("seed count must be a nonnegative integer");
            }
            let count = u64::try_from(text::decimal(count)).unwrap_or(u64::MAX);
            store.reset_for_seed();
            let _ = store.locked(|s| s.seed_entries(count));
            print_line(&format!("{{\"ok\":true,\"seeded\":{count}}}"));
        }
        "backfill" => {
            or_fail(store.ensure());
            let filled = store.locked(|s| Ok(s.backfill_previews())).unwrap_or(0);
            print_line(&format!("{{\"ok\":true,\"filled\":{filled}}}"));
        }
        "prune" => {
            or_fail(store.ensure());
            let _ = store.locked(Store::prune);
            print_line(r#"{"ok":true,"pruned":true}"#);
        }
        _ => {
            eprint!("{USAGE}");
            return ExitCode::from(64);
        }
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    foamy_helper::process::exit_on_panic(101);
    // A panic still answers with JSON (the kit's hook then exits 101).
    let kit_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        print_line(r#"{"ok":false,"error":"internal error"}"#);
        kit_hook(info);
    }));
    let raw: Vec<OsString> = std::env::args_os().skip(1).collect();
    if raw.first().is_some_and(|a| a == "favicon") {
        return foamy_helper::favicon::run();
    }
    foamy_helper::process::set_umask(0o077);
    let args: Vec<String> = raw
        .into_iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    run(args)
}
