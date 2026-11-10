// foamy-kit 0.7.0 34a2d3b505a93d36d0c874c5aa03e105e49ec885e85d941979b5b14aeba9db99 — do not edit; change foamy-kit and run sync
//! JSON lines: one compact JSON value per `\n`-terminated line, and
//! [`run`], the entry point that prints JSON for every outcome (success,
//! failure and panic) so the QML side always gets a reply it can parse.

use std::fmt;
use std::io::{self, BufRead, ErrorKind, Write};
use std::process::ExitCode;
use std::sync::Arc;

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

/// Runs a one-shot helper and prints exactly one JSON reply on standard
/// output: `main`'s value (exit 0) or `render(&failure)` (the failure's exit
/// code). A panic prints `render` of an `INTERNAL` failure and exits with
/// 101 straight from the panic hook (the panic message still goes to
/// standard error), so a helper bug never ends in `SIGABRT` and a core dump
/// under the kit's `panic = "abort"`.
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
    let on_panic = Arc::clone(&render);
    crate::process::exit_on_panic_after(101, move || {
        let _ = print_line(&on_panic(&Failure::coded("INTERNAL", "internal error")));
    });
    let (reply, exit) = reply_for(main(), &*render);
    match print_line(&reply) {
        Ok(()) => ExitCode::from(exit),
        Err(_) => ExitCode::from(if exit == 0 { 1 } else { exit }),
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
