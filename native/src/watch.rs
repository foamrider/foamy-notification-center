//! `watch`: follow the source and the store with `inotifywait` (same argv as
//! before) and stream archived rows and events, one JSON line each.

use std::fs;
use std::io::{self, Read};
use std::os::fd::AsFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::process::Signal;

use crate::store::{Store, print_line};
use crate::{fail, text};

const STORE_CHANGED: &str = r#"{"event":"storeChanged"}"#;

fn epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn is_dir(path: &str) -> bool {
    fs::metadata(path).is_ok_and(|m| m.is_dir())
}

/// inotifywait's merged output, line by line, with a deadline per read.
struct Events {
    pipe: io::PipeReader,
    buffer: Vec<u8>,
    eof: bool,
}

enum Next {
    Line(String),
    Timeout,
    End,
}

impl Events {
    /// The next line; `wait` None blocks, Some(seconds) times out.
    fn next(&mut self, wait: Option<i64>) -> Next {
        loop {
            if let Some(at) = self.buffer.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=at).collect();
                return Next::Line(String::from_utf8_lossy(&line[..line.len() - 1]).into_owned());
            }
            if self.eof {
                return Next::End;
            }
            let timeout = wait.map(|s| Timespec {
                tv_sec: s.max(0) as _,
                tv_nsec: 0,
            });
            let mut fds = [PollFd::from_borrowed_fd(self.pipe.as_fd(), PollFlags::IN)];
            match poll(&mut fds, timeout.as_ref()) {
                Ok(0) => return Next::Timeout,
                Ok(_) => {}
                Err(rustix::io::Errno::INTR) => continue,
                Err(_) => return Next::End,
            }
            let mut chunk = [0u8; 8192];
            match self.pipe.read(&mut chunk) {
                Ok(0) => self.eof = true,
                Ok(n) => self.buffer.extend_from_slice(&chunk[..n]),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => self.eof = true,
            }
        }
    }
}

/// The running inotifywait; killed whenever the watcher ends.
struct Watcher(Child);

impl Watcher {
    fn stop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }

    /// The old script's `die` under `watch`: the watcher goes first.
    fn die(&mut self, message: &str) -> ! {
        self.stop();
        fail(message)
    }
}

/// `[[ $file == "$dir/"*.json ]]`.
fn source_json(file: &str, dir: &str) -> bool {
    let prefix = format!("{dir}/");
    file.len() >= prefix.len() + 5 && file.starts_with(&prefix) && file.ends_with(".json")
}

pub fn run(store: &mut Store) -> ! {
    if let Err(message) = store.ensure() {
        fail(&message);
    }
    store.watching = true;
    // Watch only what exists; never create directories in another plugin's
    // state. A missing source directory is watched through its nearest
    // existing ancestor; when it appears, the watcher syncs and asks to be
    // restarted so the new directory gets its own watch.
    let mut watch_paths = vec![store.dir.clone()];
    let mut missing = Vec::new();
    let mut candidates = vec![
        store.src_dir.clone(),
        store.src_history.clone(),
        store.source_state_dir.clone(),
    ];
    if !store.handled.is_empty() {
        candidates.push(text::dirname(&store.handled));
    }
    candidates.push(text::dirname(&store.dnd_files[0]));
    for path in candidates {
        let mut ancestor = path.clone();
        if !is_dir(&path) {
            missing.push(path.clone());
            while !is_dir(&ancestor) && ancestor.len() > 1 && ancestor.starts_with('/') {
                ancestor = text::dirname(&ancestor);
            }
            if !is_dir(&ancestor) || ancestor == "/" {
                continue;
            }
        }
        if !watch_paths.contains(&ancestor) {
            watch_paths.push(ancestor);
        }
    }
    let (reader, writer) = match io::pipe() {
        Ok(pipe) => pipe,
        Err(_) => fail("notification watcher failed to start"),
    };
    let mut command = Command::new("inotifywait");
    command
        .env("LC_ALL", "C")
        .args([
            "-m",
            "-e",
            "close_write",
            "-e",
            "moved_to",
            "-e",
            "delete",
            "-e",
            "create",
            "-e",
            "delete_self",
            "-e",
            "move_self",
        ])
        .args(["--format", "%e|%w%f"])
        .args(&watch_paths)
        .stdin(Stdio::null());
    match writer.try_clone() {
        Ok(copy) => command.stdout(copy).stderr(writer),
        Err(_) => fail("notification watcher failed to start"),
    };
    // SAFETY: runs in the forked child before exec and only makes the prctl
    // system call (async-signal-safe, no allocation).
    unsafe {
        command.pre_exec(|| {
            rustix::process::set_parent_process_death_signal(Some(Signal::KILL))?;
            Ok(())
        });
    }
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fail("inotifywait is not installed")
        }
        Err(_) => fail("notification watcher failed to start"),
    };
    drop(command);
    let mut watcher = Watcher(child);
    let mut events = Events {
        pipe: reader,
        buffer: Vec::new(),
        eof: false,
    };
    // Establish watches before startup reconciliation so arrivals cannot fall into a gap.
    loop {
        match events.next(None) {
            Next::Line(line) if line == "Watches established." => break,
            Next::Line(_) | Next::Timeout => continue,
            Next::End => watcher.die("notification watcher failed to start"),
        }
    }
    if let Err(message) = crate::sync(store) {
        watcher.die(&message);
    }
    print_line(STORE_CHANGED);
    // Retention runs on a wall-clock deadline (hourly by default), not an
    // idle timeout, so steady traffic cannot starve it.
    let interval = std::env::var("NC_RETENTION_INTERVAL")
        .ok()
        .filter(|v| text::all_digits(v))
        .map(|v| text::decimal(&v))
        .filter(|&v| v > 0)
        .map_or(3600, |v| v.min(i64::MAX as i128 / 2) as i64);
    let mut next_retention = epoch_seconds() + interval;
    loop {
        let wait = next_retention - epoch_seconds();
        if wait <= 0 {
            if store.locked(Store::prune).is_err() {
                watcher.die("cannot apply notification retention");
            }
            print_line(STORE_CHANGED);
            next_retention = epoch_seconds() + interval;
            continue;
        }
        let line = match events.next(Some(wait)) {
            Next::Line(line) => line,
            Next::Timeout => continue,
            Next::End => break,
        };
        let (event, file) = match line.split_once('|') {
            Some((event, rest)) => (
                event.to_string(),
                rest.strip_suffix('|').unwrap_or(rest).to_string(),
            ),
            None => (line.clone(), String::new()),
        };
        if event.contains("DELETE_SELF") || event.contains("MOVE_SELF") {
            watcher.die("notification source changed; reconnecting");
        } else if event.contains("Q_OVERFLOW") {
            if let Err(message) = crate::sync(store) {
                watcher.die(&message);
            }
            print_line(STORE_CHANGED);
        } else if file == format!("{}/archive.jsonl", store.dir)
            || file == store.cleared_at
            || file == store.dismissed
        {
            print_line(STORE_CHANGED);
        } else if store.dnd_files.contains(&file) {
            print_line(r#"{"event":"dndChanged"}"#);
        } else if !store.handled.is_empty() && file == store.handled {
            if !event.contains("DELETE") && store.locked(Store::apply_handled).is_err() {
                watcher.die("cannot update notification archive");
            }
        } else if event.contains("ISDIR")
            && missing
                .iter()
                .any(|path| *path == file || path.starts_with(&format!("{file}/")))
        {
            // Keep the stream: ingested rows and `pruned` events must reach the service.
            if store.locked(Store::sync_and_prune).is_err() {
                watcher.die("cannot update notification archive");
            }
            print_line(r#"{"event":"rewatch"}"#);
            watcher.stop();
            std::process::exit(0);
        } else if event.starts_with("CREATE") {
            // Ordinary JSON writes are ingested only when complete.
            continue;
        } else if file == store.seen {
            print_line(r#"{"event":"seenChanged"}"#);
        } else if (source_json(&file, &store.src_dir) || source_json(&file, &store.src_history))
            && !event.contains("DELETE")
            && store.locked(|s| s.ingest_one(&file)).is_err()
        {
            watcher.die("cannot update notification archive");
        }
    }
    watcher.die("notification watcher stopped")
}
