// foamy-kit 0.16.0 111a50e13415ed5ca0fee6b226b655db8cf67ea266fcfd485e01cbe0c03f7b05 — do not edit; change foamy-kit and run sync
//! Bounded reads: whole streams with a byte cap, and lines with a maximum
//! length that skip (rather than buffer) an overlong line.

use std::error::Error;
use std::fmt;
use std::io::{self, BufRead, ErrorKind, Read};
use std::os::fd::{AsFd, BorrowedFd};
use std::time::Instant;

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::io::Errno;

/// The error inside an [`io::Error`] when input is larger than its cap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TooLarge {
    /// The cap in bytes.
    pub limit: u64,
}

impl fmt::Display for TooLarge {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "input is larger than {} bytes", self.limit)
    }
}

impl Error for TooLarge {}

/// The error inside an [`io::Error`] when a line is longer than its cap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineTooLong {
    /// The cap in bytes (without the newline).
    pub limit: usize,
}

impl fmt::Display for LineTooLong {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line is longer than {} bytes", self.limit)
    }
}

impl Error for LineTooLong {}

/// Whether `error` reports input over a cap ([`TooLarge`] or [`LineTooLong`]),
/// also when the cap error is the source of the error inside it (as with
/// [`crate::fs::read_file_limited`], which adds the path to the message).
pub fn is_over_limit(error: &io::Error) -> bool {
    let mut next = error.get_ref().map(|inner| inner as &(dyn Error + 'static));
    while let Some(inner) = next {
        if inner.is::<TooLarge>() || inner.is::<LineTooLong>() {
            return true;
        }
        next = inner.source();
    }
    false
}

/// Reads `reader` to its end, failing with [`TooLarge`] (kind
/// `InvalidData`) once it yields more than `limit` bytes. At most
/// `limit + 1` bytes are read.
pub fn read_limited<R: Read>(reader: R, limit: u64) -> io::Result<Vec<u8>> {
    let mut data = Vec::new();
    reader
        .take(limit.saturating_add(1))
        .read_to_end(&mut data)?;
    if data.len() as u64 > limit {
        return Err(io::Error::new(ErrorKind::InvalidData, TooLarge { limit }));
    }
    Ok(data)
}

/// [`read_limited`] as UTF-8 text (invalid UTF-8 is `InvalidData`).
pub fn read_limited_string<R: Read>(reader: R, limit: u64) -> io::Result<String> {
    String::from_utf8(read_limited(reader, limit)?)
        .map_err(|_| io::Error::new(ErrorKind::InvalidData, "input is not valid UTF-8"))
}

/// Reads all of standard input, at most `limit` bytes.
///
/// When the helper set a run budget ([`crate::process::set_run_budget`]),
/// standard input must also end by then: a caller that writes its request
/// but never closes the pipe would otherwise keep the helper waiting with no
/// end. Past the deadline the read fails with kind `TimedOut`.
pub fn read_stdin_limited(limit: u64) -> io::Result<Vec<u8>> {
    match crate::process::run_deadline() {
        Some(deadline) => read_fd_until(io::stdin().as_fd(), limit, deadline),
        None => read_limited(io::stdin().lock(), limit),
    }
}

/// [`read_limited`] on a file descriptor that must reach its end before
/// `deadline`: each read waits in `poll` for at most the time left.
fn read_fd_until(fd: BorrowedFd<'_>, limit: u64, deadline: Instant) -> io::Result<Vec<u8>> {
    let mut data = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(io::Error::new(
                ErrorKind::TimedOut,
                "input did not end before the deadline",
            ));
        }
        let wait = Timespec {
            tv_sec: left.as_secs() as _,
            tv_nsec: left.subsec_nanos() as _,
        };
        let mut polled = [PollFd::new(&fd, PollFlags::IN)];
        match poll(&mut polled, Some(&wait)) {
            // Nothing yet: the next turn checks the deadline.
            Ok(0) | Err(Errno::INTR) => continue,
            Ok(_) => {}
            Err(error) => return Err(error.into()),
        }
        let read = match rustix::io::read(fd, &mut buffer) {
            Ok(read) => read,
            Err(Errno::INTR | Errno::AGAIN) => continue,
            Err(error) => return Err(error.into()),
        };
        if read == 0 {
            return Ok(data);
        }
        data.extend_from_slice(&buffer[..read]);
        if data.len() as u64 > limit {
            return Err(io::Error::new(ErrorKind::InvalidData, TooLarge { limit }));
        }
    }
}

/// Reads `\n`-terminated lines of at most `limit` bytes each.
///
/// A longer line is consumed up to its newline without being buffered and
/// reported as [`LineTooLong`] (kind `InvalidData`); the next call continues
/// with the following line, so a caller can answer with an error and go on.
/// The newline is not part of the returned line; a last line without one is
/// still returned.
#[derive(Debug)]
pub struct LineReader<R> {
    inner: R,
    limit: usize,
}

impl<R: BufRead> LineReader<R> {
    /// Wraps a buffered reader; `limit` is the longest accepted line in bytes.
    pub fn new(inner: R, limit: usize) -> Self {
        LineReader { inner, limit }
    }

    /// The next line, `Ok(None)` at the end of the input.
    pub fn read_line(&mut self) -> io::Result<Option<Vec<u8>>> {
        let mut line = Vec::new();
        let mut started = false;
        let mut too_long = false;
        loop {
            let buffer = match self.inner.fill_buf() {
                Ok(buffer) => buffer,
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            };
            if buffer.is_empty() {
                if !started {
                    return Ok(None);
                }
                break;
            }
            started = true;
            let newline = buffer.iter().position(|&byte| byte == b'\n');
            let chunk = &buffer[..newline.unwrap_or(buffer.len())];
            if !too_long {
                if line.len() + chunk.len() > self.limit {
                    too_long = true;
                    line = Vec::new();
                } else {
                    line.extend_from_slice(chunk);
                }
            }
            let used = newline.map_or(buffer.len(), |index| index + 1);
            self.inner.consume(used);
            if newline.is_some() {
                break;
            }
        }
        if too_long {
            return Err(io::Error::new(
                ErrorKind::InvalidData,
                LineTooLong { limit: self.limit },
            ));
        }
        Ok(Some(line))
    }

    /// [`read_line`](Self::read_line) as UTF-8 text (invalid UTF-8 is
    /// `InvalidData`; the line is consumed either way).
    pub fn read_line_string(&mut self) -> io::Result<Option<String>> {
        match self.read_line()? {
            None => Ok(None),
            Some(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| io::Error::new(ErrorKind::InvalidData, "line is not valid UTF-8")),
        }
    }

    /// The wrapped reader.
    pub fn into_inner(self) -> R {
        self.inner
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufReader, Cursor, Write};
    use std::time::Duration;

    #[test]
    fn a_pipe_left_open_ends_at_the_deadline() {
        let (reader, writer) = rustix::pipe::pipe().unwrap();
        let mut writer = std::fs::File::from(writer);
        writer.write_all(b"{\"text\":\"x\"}").unwrap();
        // The writer stays open: without a deadline this read never ends.
        let started = Instant::now();
        let deadline = started + Duration::from_millis(200);
        let error = read_fd_until(reader.as_fd(), 1024, deadline).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::TimedOut);
        assert!(started.elapsed() >= Duration::from_millis(200));
        assert!(started.elapsed() < Duration::from_secs(2));
        drop(writer);
    }

    #[test]
    fn a_closed_pipe_is_read_to_its_end_within_the_limit() {
        let (reader, writer) = rustix::pipe::pipe().unwrap();
        let mut writer = std::fs::File::from(writer);
        writer.write_all(b"abcd").unwrap();
        drop(writer);
        let deadline = Instant::now() + Duration::from_secs(5);
        assert_eq!(read_fd_until(reader.as_fd(), 4, deadline).unwrap(), b"abcd");
        let (reader, writer) = rustix::pipe::pipe().unwrap();
        let mut writer = std::fs::File::from(writer);
        writer.write_all(b"abcde").unwrap();
        drop(writer);
        let error = read_fd_until(reader.as_fd(), 4, deadline).unwrap_err();
        assert!(is_over_limit(&error));
        // A deadline already past fails before any read.
        let error = read_fd_until(reader.as_fd(), 4, Instant::now()).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::TimedOut);
    }

    #[test]
    fn read_limited_accepts_exactly_the_limit() {
        assert_eq!(read_limited(Cursor::new(b"abcd"), 4).unwrap(), b"abcd");
        assert_eq!(read_limited(Cursor::new(b""), 0).unwrap(), b"");
    }

    #[test]
    fn read_limited_rejects_one_byte_more() {
        let error = read_limited(Cursor::new(b"abcde"), 4).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidData);
        assert!(is_over_limit(&error));
        assert_eq!(error.to_string(), "input is larger than 4 bytes");
    }

    #[test]
    fn read_limited_stops_reading_after_the_limit() {
        struct Endless(u64);
        impl Read for Endless {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                self.0 += buffer.len() as u64;
                buffer.fill(b'x');
                Ok(buffer.len())
            }
        }
        let mut source = Endless(0);
        assert!(read_limited(&mut source, 10).is_err());
        assert!(source.0 <= 4096 + 11, "read {} bytes", source.0);
    }

    #[test]
    fn read_limited_string_rejects_invalid_utf8() {
        assert_eq!(read_limited_string(Cursor::new("é"), 8).unwrap(), "é");
        let error = read_limited_string(Cursor::new(b"\xff"), 8).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidData);
        assert!(!is_over_limit(&error));
    }

    #[test]
    fn lines_split_on_newline_and_keep_a_last_partial_line() {
        let mut reader = LineReader::new(Cursor::new(b"one\n\ntwo\r\nthree"), 16);
        assert_eq!(reader.read_line().unwrap().unwrap(), b"one");
        assert_eq!(reader.read_line().unwrap().unwrap(), b"");
        assert_eq!(reader.read_line().unwrap().unwrap(), b"two\r");
        assert_eq!(reader.read_line().unwrap().unwrap(), b"three");
        assert!(reader.read_line().unwrap().is_none());
        assert!(reader.read_line().unwrap().is_none());
    }

    #[test]
    fn overlong_line_is_reported_and_skipped() {
        // A tiny buffer makes the long line span many fill_buf calls.
        let input = Cursor::new(b"ok\nthis line is too long\nnext\n".to_vec());
        let mut reader = LineReader::new(BufReader::with_capacity(3, input), 5);
        assert_eq!(reader.read_line().unwrap().unwrap(), b"ok");
        let error = reader.read_line().unwrap_err();
        assert!(is_over_limit(&error));
        assert_eq!(error.to_string(), "line is longer than 5 bytes");
        assert_eq!(reader.read_line().unwrap().unwrap(), b"next");
        assert!(reader.read_line().unwrap().is_none());
    }

    #[test]
    fn line_of_exactly_the_limit_is_accepted() {
        let mut reader = LineReader::new(Cursor::new(b"12345\n123456"), 5);
        assert_eq!(reader.read_line().unwrap().unwrap(), b"12345");
        assert!(is_over_limit(&reader.read_line().unwrap_err()));
        assert!(reader.read_line().unwrap().is_none());
    }

    #[test]
    fn line_strings_reject_invalid_utf8_and_continue() {
        let mut reader = LineReader::new(Cursor::new(b"\xff\nfine\n"), 16);
        assert_eq!(
            reader.read_line_string().unwrap_err().kind(),
            ErrorKind::InvalidData
        );
        assert_eq!(reader.read_line_string().unwrap().unwrap(), "fine");
    }
}
