// foamy-kit 0.15.1 2e913dfb3c53284abbb850d81be9b9cd690cd3f2567d676bf8b70ae314542cf6 — do not edit; change foamy-kit and run sync
//! JSON lines: one compact JSON value per `\n`-terminated line, and
//! [`run`], the entry point that prints JSON for every outcome (success,
//! failure and panic) so the QML side always gets a reply it can parse
//! ([`run_bytes`] for a reply line the helper encodes itself).

use std::fmt;
use std::io::{self, BufRead, ErrorKind, Write};
use std::process::ExitCode;
use std::sync::{Arc, Mutex, PoisonError};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::io::LineReader;

/// A failure a helper reports as JSON: a stable machine-readable `code`, a
/// human-readable `message` and the process exit code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    /// Machine-readable code, e.g. `"BUSY"` or `"INVALID_ARGUMENT"`.
    pub code: String,
    /// Message for logs or the UI.
    pub message: String,
    /// Exit code of the helper when this failure ends it (default 1).
    pub exit_code: u8,
}

impl Failure {
    /// A failure with code `"ERROR"` and exit code 1.
    pub fn new(message: impl Into<String>) -> Self {
        Failure::coded("ERROR", message)
    }

    /// A failure with the given code and exit code 1.
    pub fn coded(code: impl Into<String>, message: impl Into<String>) -> Self {
        Failure {
            code: code.into(),
            message: message.into(),
            exit_code: 1,
        }
    }

    /// The same failure ending the helper with `exit_code`. 126 and 127 are
    /// reserved for "helper unavailable" (`FoamyNative.unavailable()`), so
    /// [`run`] reports them as 1.
    pub fn with_exit_code(mut self, exit_code: u8) -> Self {
        self.exit_code = exit_code;
        self
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl<E: std::error::Error> From<E> for Failure {
    fn from(error: E) -> Self {
        Failure::new(error.to_string())
    }
}

/// The default error reply: `{"ok":false,"code":…,"error":…}`. Helpers with
/// an existing contract pass their own renderer to [`run`] instead.
pub fn error_reply(failure: &Failure) -> Value {
    json!({"ok": false, "code": failure.code, "error": failure.message})
}

/// `value` as one line of compact JSON, ending in `\n`. JSON strings escape
/// control characters, so the line never contains another newline.
pub fn to_line<T: Serialize + ?Sized>(value: &T) -> io::Result<Vec<u8>> {
    let mut line =
        serde_json::to_vec(value).map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
    line.push(b'\n');
    Ok(line)
}

/// Writes `value` as one JSON line and flushes.
pub fn write_line<W: Write + ?Sized, T: Serialize + ?Sized>(
    output: &mut W,
    value: &T,
) -> io::Result<()> {
    output.write_all(&to_line(value)?)?;
    output.flush()
}

/// Writes `value` as one JSON line to standard output and flushes.
pub fn print_line<T: Serialize + ?Sized>(value: &T) -> io::Result<()> {
    write_line(&mut io::stdout().lock(), value)
}

/// Parses one JSON request; a malformed one is an `INVALID_REQUEST` failure.
pub fn parse<T: DeserializeOwned>(line: &[u8]) -> Result<T, Failure> {
    serde_json::from_slice(line)
        .map_err(|error| Failure::coded("INVALID_REQUEST", format!("invalid request: {error}")))
}

/// Serves a JSON-lines protocol until `input` ends: each line (at most
/// `max_line` bytes) is parsed as a `T` and handed to `handle`, whose reply,
/// if any, is written as one line and flushed. An overlong, non-UTF-8 or
/// malformed line reaches `handle` as an `INVALID_REQUEST` failure and the
/// loop goes on with the next line. Blank lines are skipped. Read errors
/// other than those, and write errors, end the loop with the error.
///
/// A panic in `handle` exits the process with 101 (see
/// [`crate::process::exit_on_panic`], installed here) and writes nothing
/// more, so the peer sees the stream end rather than a torn reply.
pub fn serve<R, W, T, S, F>(
    input: R,
    mut output: W,
    max_line: usize,
    mut handle: F,
) -> io::Result<()>
where
    R: BufRead,
    W: Write,
    T: DeserializeOwned,
    S: Serialize,
    F: FnMut(Result<T, Failure>) -> Option<S>,
{
    // Not under the crate's own unit tests: a failing assertion elsewhere
    // in the test binary must stay a failed test, not an exit.
    #[cfg(not(test))]
    crate::process::exit_on_panic(101);
    let mut lines = LineReader::new(input, max_line);
    loop {
        let request = match lines.read_line() {
            Ok(None) => return Ok(()),
            Ok(Some(line)) if line.iter().all(u8::is_ascii_whitespace) => continue,
            Ok(Some(line)) => parse(&line),
            Err(error) if error.kind() == ErrorKind::InvalidData => {
                Err(Failure::coded("INVALID_REQUEST", error.to_string()))
            }
            Err(error) => return Err(error),
        };
        if let Some(reply) = handle(request) {
            write_line(&mut output, &reply)?;
        }
    }
}

fn reply_for<T: Serialize>(
    outcome: Result<T, Failure>,
    render: &dyn Fn(&Failure) -> Value,
) -> (Value, u8) {
    let failed = |failure: &Failure| {
        let exit = match failure.exit_code {
            126 | 127 => 1,
            code => code,
        };
        (render(failure), exit)
    };
    match outcome {
        Ok(value) => match serde_json::to_value(&value) {
            Ok(reply) => (reply, 0),
            Err(error) => failed(&Failure::coded(
                "INTERNAL",
                format!("could not encode the reply: {error}"),
            )),
        },
        Err(failure) => failed(&failure),
    }
}

/// Set by whichever of [`run`] (or [`run_bytes`]) and its panic hook prints
/// first: the other prints nothing. Held while the reply is written, so a
/// panic in another thread meanwhile waits for the whole line instead of
/// exiting in the middle of it.
static REPLIED: Mutex<bool> = Mutex::new(false);

/// Runs `write` (which prints the reply) unless a reply was printed already
/// (then `None`).
fn reply_once(write: impl FnOnce() -> io::Result<()>) -> Option<io::Result<()>> {
    // Only `write` runs under the lock, and it returns errors rather than
    // panicking; a panic there would make the hook wait for itself.
    let mut replied = REPLIED.lock().unwrap_or_else(PoisonError::into_inner);
    if *replied {
        return None;
    }
    *replied = true;
    Some(write())
}

/// Installs the kit's panic hook for a one-shot reply: `render` of an
/// `INTERNAL` failure, unless a reply is out already, then exit 101.
fn reply_on_panic<R>(render: Arc<R>)
where
    R: Fn(&Failure) -> Value + Send + Sync + 'static,
{
    crate::process::exit_on_panic_after(101, move || {
        let reply = render(&Failure::coded("INTERNAL", "internal error"));
        let _ = reply_once(|| print_line(&reply));
    });
}

/// The exit code once the reply is printed (`written`), `exit` being the
/// outcome's.
fn exit_after(written: Option<io::Result<()>>, exit: u8) -> ExitCode {
    match written {
        // Another thread panicked: the hook printed and is exiting.
        None => ExitCode::from(101),
        // A panic began while the reply was written: its hook exits 101
        // once the line is out, and `main` returning this ends it the same.
        Some(_) if crate::process::panicking() => ExitCode::from(101),
        Some(Ok(())) => ExitCode::from(exit),
        Some(Err(_)) => ExitCode::from(if exit == 0 { 1 } else { exit }),
    }
}

/// Runs a one-shot helper and prints exactly one JSON reply on standard
/// output: `main`'s value (exit 0) or `render(&failure)` (the failure's exit
/// code). A panic prints `render` of an `INTERNAL` failure and exits with
/// 101 straight from the panic hook (the panic message still goes to
/// standard error), so a helper bug never ends in `SIGABRT` and a core dump
/// under the kit's `panic = "abort"`. A panic in another thread after the
/// reply prints no second one. One while the reply is written waits until
/// the whole line is out, and `run` then returns 101 too, so the process
/// ends in 101 whether the hook or `main` ends it. A panic after `run` has
/// returned ends in 101 only if the hook exits before `main` returns.
///
/// When the caller wraps the helper in `timeout`, call
/// [`crate::process::set_run_budget`] with less than that first, so every
/// child ends in time and this reply is printed before the wrapper kills.
///
/// ```no_run
/// use foamy_helper::{Failure, json};
/// fn main() -> std::process::ExitCode {
///     json::run(|| -> Result<serde_json::Value, Failure> { Ok(serde_json::json!({"ok": true})) }, json::error_reply)
/// }
/// ```
pub fn run<T, F, R>(main: F, render: R) -> ExitCode
where
    T: Serialize,
    F: FnOnce() -> Result<T, Failure>,
    R: Fn(&Failure) -> Value + Send + Sync + 'static,
{
    let render = Arc::new(render);
    reply_on_panic(Arc::clone(&render));
    let (reply, exit) = reply_for(main(), &*render);
    exit_after(reply_once(|| print_line(&reply)), exit)
}

/// [`run`] for a helper that builds its reply line itself (a sample it
/// encodes on its own): `main` returns the finished bytes, which are
/// written to standard output as they are and flushed, under the same
/// reply lock and panic hook as [`run`]'s reply. So a panic in another
/// thread waits until the whole line is out, a panic after it prints no
/// second reply, a panic before it prints `render` of an `INTERNAL`
/// failure, and the process ends in 101 for a panic, 0 once the bytes are
/// out (1 when writing them fails). An `Err` from `main` prints
/// `render(&failure)` and ends with its exit code, as [`run`] does. Give
/// `main` one JSON line ending in `\n` (see [`to_line`]): the QML side
/// reads standard output as one reply.
///
/// ```no_run
/// use foamy_helper::{Failure, json};
/// fn main() -> std::process::ExitCode {
///     json::run_bytes(|| -> Result<Vec<u8>, Failure> { Ok(b"{\"ok\":true}\n".to_vec()) }, json::error_reply)
/// }
/// ```
pub fn run_bytes<F, R>(main: F, render: R) -> ExitCode
where
    F: FnOnce() -> Result<Vec<u8>, Failure>,
    R: Fn(&Failure) -> Value + Send + Sync + 'static,
{
    let render = Arc::new(render);
    reply_on_panic(Arc::clone(&render));
    match main() {
        Ok(line) => exit_after(
            reply_once(|| {
                let mut stdout = io::stdout().lock();
                stdout.write_all(&line).and_then(|()| stdout.flush())
            }),
            0,
        ),
        Err(failure) => {
            let (reply, exit) = reply_for::<Value>(Err(failure), &*render);
            exit_after(reply_once(|| print_line(&reply)), exit)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn lines_are_compact_and_single_line() {
        let line = to_line(&json!({"text": "a\nb", "n": 1})).unwrap();
        assert_eq!(line, b"{\"n\":1,\"text\":\"a\\nb\"}\n");
        assert_eq!(line.iter().filter(|&&b| b == b'\n').count(), 1);
    }

    #[test]
    fn failures_convert_from_errors() {
        let failure: Failure = io::Error::other("disk on fire").into();
        assert_eq!(
            failure,
            Failure {
                code: "ERROR".into(),
                message: "disk on fire".into(),
                exit_code: 1
            }
        );
        assert_eq!(
            Failure::coded("BUSY", "later")
                .with_exit_code(3)
                .to_string(),
            "BUSY: later"
        );
        assert_eq!(
            error_reply(&Failure::coded("BUSY", "later")),
            json!({"ok": false, "code": "BUSY", "error": "later"})
        );
    }

    #[test]
    fn parse_reports_invalid_requests() {
        assert_eq!(parse::<Value>(b"[1]").unwrap(), json!([1]));
        let failure = parse::<Value>(b"{nope").unwrap_err();
        assert_eq!(failure.code, "INVALID_REQUEST");
    }

    #[test]
    fn serve_answers_every_line_and_survives_bad_ones() {
        let input = Cursor::new(b"{\"id\":1}\n\n   \nnot json\n{\"id\":2,\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}\n{\"id\":3}".to_vec());
        let mut output = Vec::new();
        serve(input, &mut output, 24, |request: Result<Value, Failure>| {
            Some(match request {
                Ok(request) => json!({"id": request["id"]}),
                Err(failure) => json!({"error": failure.code, "message": failure.message}),
            })
        })
        .unwrap();
        let replies: Vec<Value> = output
            .split(|&b| b == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_slice(l).unwrap())
            .collect();
        assert_eq!(replies.len(), 4);
        assert_eq!(replies[0], json!({"id": 1}));
        assert_eq!(replies[1]["error"], "INVALID_REQUEST");
        assert_eq!(replies[2]["error"], "INVALID_REQUEST");
        assert_eq!(replies[2]["message"], "line is longer than 24 bytes");
        assert_eq!(replies[3], json!({"id": 3}));
    }

    #[test]
    fn serve_can_stay_silent() {
        let mut output = Vec::new();
        serve(
            Cursor::new(b"{\"id\":1}\n".to_vec()),
            &mut output,
            64,
            |_: Result<Value, Failure>| None::<Value>,
        )
        .unwrap();
        assert!(output.is_empty());
    }

    /// [`a_panic_after_the_reply_prints_no_second_one`]'s child: a thread
    /// that panics once `run` has replied. Run normally it does nothing.
    #[test]
    fn late_panic_child() {
        if std::env::var_os("FOAMY_JSON_TEST").is_none() {
            return;
        }
        let exit = run(
            || -> Result<Value, Failure> {
                std::thread::spawn(|| {
                    std::thread::sleep(std::time::Duration::from_millis(200));
                    panic!("a bug in a worker thread");
                });
                Ok(json!({"ok": true}))
            },
            error_reply,
        );
        assert_eq!(exit, ExitCode::SUCCESS);
        std::thread::sleep(std::time::Duration::from_secs(5));
    }

    #[test]
    fn a_panic_after_the_reply_prints_no_second_one() {
        let output = crate::child::Bounded::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "json::tests::late_panic_child",
                "--nocapture",
                "--test-threads=1",
                "-q",
            ])
            .env("FOAMY_JSON_TEST", "1")
            .timeout(std::time::Duration::from_secs(30))
            .run()
            .unwrap();
        assert_eq!(output.status.code(), Some(101), "{output:?}");
        let replies: Vec<&str> = std::str::from_utf8(&output.stdout)
            .unwrap()
            .lines()
            .filter(|line| line.starts_with('{'))
            .collect();
        assert_eq!(replies, ["{\"ok\":true}"], "{output:?}");
    }

    /// [`run_bytes_prints_the_line_or_one_reply`]'s child: `run_bytes` with
    /// the outcome FOAMY_JSON_TEST_BYTES names, then the exit code it
    /// returned. Run normally it does nothing.
    #[test]
    fn run_bytes_child() {
        let Some(mode) = std::env::var_os("FOAMY_JSON_TEST_BYTES") else {
            return;
        };
        let exit = run_bytes(
            move || -> Result<Vec<u8>, Failure> {
                match mode.to_str() {
                    Some("line") => Ok(b"{\"raw\":[1,2]}\n".to_vec()),
                    Some("failure") => {
                        Err(Failure::coded("INVALID_ARGUMENT", "usage: x").with_exit_code(2))
                    }
                    _ => panic!("a bug before the reply"),
                }
            },
            error_reply,
        );
        let code = [0u8, 1, 2, 101]
            .into_iter()
            .find(|&code| exit == ExitCode::from(code))
            .map_or(7, i32::from);
        std::process::exit(code);
    }

    #[test]
    fn run_bytes_prints_the_line_or_one_reply() {
        for (mode, code, reply) in [
            ("line", 0, "{\"raw\":[1,2]}"),
            (
                "failure",
                2,
                "{\"code\":\"INVALID_ARGUMENT\",\"error\":\"usage: x\",\"ok\":false}",
            ),
            (
                "panic",
                101,
                "{\"code\":\"INTERNAL\",\"error\":\"internal error\",\"ok\":false}",
            ),
        ] {
            let output = crate::child::Bounded::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "json::tests::run_bytes_child",
                    "--nocapture",
                    "--test-threads=1",
                    "-q",
                ])
                .env("FOAMY_JSON_TEST_BYTES", mode)
                .timeout(std::time::Duration::from_secs(30))
                .run()
                .unwrap();
            assert_eq!(output.status.code(), Some(code), "{mode}: {output:?}");
            let replies: Vec<&str> = std::str::from_utf8(&output.stdout)
                .unwrap()
                .lines()
                .filter(|line| line.starts_with('{'))
                .collect();
            assert_eq!(replies, [reply], "{mode}: {output:?}");
        }
    }

    /// [`a_panic_while_the_reply_is_written_waits_for_it`]'s child: a reply
    /// four times the size of the stdout pipe, and a thread that panics
    /// once the reply is in the middle of being written: by `run`, or by
    /// `run_bytes` when FOAMY_JSON_TEST_DURING is "bytes". It then exits
    /// with the returned code at once, as a helper whose `main` returns it
    /// does. Run normally it does nothing.
    #[test]
    fn panic_during_reply_child() {
        let Some(mode) = std::env::var_os("FOAMY_JSON_TEST_DURING") else {
            return;
        };
        let pipe = rustix::pipe::fcntl_getpipe_size(io::stdout()).unwrap();
        let reply = move || {
            std::thread::spawn(move || {
                // The parent does not read yet, so more than half a pipe
                // of data means the reply is being written.
                while (rustix::io::ioctl_fionread(io::stdout()).unwrap() as usize) <= pipe / 2 {
                    std::thread::yield_now();
                }
                panic!("a bug in a worker thread");
            });
            json!({"text": "x".repeat(4 * pipe)})
        };
        let exit = if mode == "bytes" {
            run_bytes(
                move || -> Result<Vec<u8>, Failure> { Ok(to_line(&reply())?) },
                error_reply,
            )
        } else {
            run(
                move || -> Result<Value, Failure> { Ok(reply()) },
                error_reply,
            )
        };
        // The worker's panic hook exits 101 at the same time; an assertion
        // here would end in that hook too, so the code tells the parent.
        std::process::exit(if exit == ExitCode::from(101) { 101 } else { 7 });
    }

    #[test]
    fn a_panic_while_the_reply_is_written_waits_for_it() {
        // The child's own exit and the panic hook's race; three runs show
        // that both end in 101.
        for _ in 0..3 {
            panic_during_reply_once("run");
        }
    }

    #[test]
    fn a_panic_while_run_bytes_writes_its_line_waits_for_it() {
        for _ in 0..3 {
            panic_during_reply_once("bytes");
        }
    }

    fn panic_during_reply_once(mode: &str) {
        use std::io::Read;
        use std::sync::mpsc;
        use std::time::Duration;
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "json::tests::panic_during_reply_child",
                "--nocapture",
                "--test-threads=1",
                "-q",
            ])
            .env("FOAMY_JSON_TEST_DURING", mode)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdout = child.stdout.take().unwrap();
        let pipe = rustix::pipe::fcntl_getpipe_size(&stdout).unwrap();
        let stderr = child.stderr.take().unwrap();
        let (panicked_tx, panicked) = mpsc::channel();
        let errors = std::thread::spawn(move || {
            let mut text = String::new();
            for line in io::BufReader::new(stderr).lines().map_while(Result::ok) {
                if line.contains("a bug in a worker thread") {
                    let _ = panicked_tx.send(());
                }
                text.push_str(&line);
                text.push('\n');
            }
            text
        });
        // Read standard output only after the panic: until then the full
        // pipe keeps `run` inside its write.
        let waited = panicked.recv_timeout(Duration::from_secs(30));
        let (read_tx, read) = mpsc::channel();
        std::thread::spawn(move || {
            let mut data = Vec::new();
            let _ = stdout.read_to_end(&mut data);
            let _ = read_tx.send(data);
        });
        let output = read.recv_timeout(Duration::from_secs(30));
        if output.is_err() {
            let _ = child.kill();
        }
        let status = child.wait().unwrap();
        let errors = errors.join().unwrap();
        assert!(waited.is_ok(), "the worker did not panic: {errors}");
        let output = output.unwrap_or_else(|_| panic!("the helper did not end: {errors}"));
        let text = String::from_utf8_lossy(&output);
        let replies: Vec<&str> = text.lines().filter(|line| line.starts_with('{')).collect();
        let expected = json!({"text": "x".repeat(4 * pipe)});
        assert!(
            replies.len() == 1 && serde_json::from_str::<Value>(replies[0]).ok() == Some(expected),
            "one whole reply line expected; got {} bytes of output, {} reply lines; {errors}",
            output.len(),
            replies.len()
        );
        assert_eq!(status.code(), Some(101), "{errors}");
    }

    #[test]
    fn reply_for_maps_outcomes() {
        assert_eq!(
            reply_for(Ok(json!({"ok": true})), &error_reply),
            (json!({"ok": true}), 0)
        );
        let (reply, exit) = reply_for::<Value>(
            Err(Failure::coded("BUSY", "x").with_exit_code(4)),
            &error_reply,
        );
        assert_eq!((reply["code"].as_str(), exit), (Some("BUSY"), 4));
        // 126 and 127 mean "helper unavailable" to the QML side.
        assert_eq!(
            reply_for::<Value>(Err(Failure::new("x").with_exit_code(127)), &error_reply).1,
            1
        );
        assert_eq!(
            reply_for::<Value>(Err(Failure::new("x").with_exit_code(126)), &error_reply).1,
            1
        );
        assert_eq!(
            reply_for::<Value>(Err(Failure::new("x").with_exit_code(0)), &error_reply).1,
            0
        );
        // A value serde can't encode still yields a JSON reply.
        let bad: std::collections::HashMap<Vec<u8>, u8> = [(vec![1], 1)].into();
        let (reply, exit) = reply_for(Ok(bad), &error_reply);
        assert_eq!((reply["code"].as_str(), exit), (Some("INTERNAL"), 1));
    }
}
