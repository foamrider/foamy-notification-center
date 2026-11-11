// foamy-kit 0.9.0 6e036b32a765a1adf8110629db1fca3c7d476d4f85f8ed7d3d44735222e2daab — do not edit; change foamy-kit and run sync
//! Network streams with an absolute deadline.
//!
//! A socket timeout (`set_read_timeout`) bounds each blocking call, not an
//! operation: a peer that trickles one byte at a time, or a TLS library that
//! makes several socket reads for one record, can stretch a "5 s" request to
//! minutes. [`DeadlineStream`] re-arms the socket timeout to the time left
//! before **every** read and write, and fails with [`DeadlineExceeded`]
//! (kind `TimedOut`) once the deadline has passed, so everything layered on
//! top of it (rustls, an HTTP parser, `read_to_end`) is bounded as a whole:
//!
//! ```no_run
//! use std::time::{Duration, Instant};
//! use foamy_helper::net::DeadlineStream;
//! # fn main() -> std::io::Result<()> {
//! let tcp = std::net::TcpStream::connect(("127.0.0.1", 8384))?;
//! let mut stream = DeadlineStream::new(tcp, Instant::now() + Duration::from_secs(5));
//! // e.g. rustls::StreamOwned::new(connection, stream), then read and write.
//! # Ok(()) }
//! ```

use std::error::Error;
use std::fmt;
use std::io::{self, ErrorKind, Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

/// The error inside an [`io::Error`] (kind `TimedOut`) when a
/// [`DeadlineStream`]'s deadline has passed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeadlineExceeded;

impl fmt::Display for DeadlineExceeded {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("deadline exceeded")
    }
}

impl Error for DeadlineExceeded {}

/// Whether `error` is a passed deadline: [`DeadlineExceeded`], or a socket
/// timeout (`TimedOut`/`WouldBlock`), anywhere in its source chain (rustls
/// and HTTP libraries wrap I/O errors).
pub fn is_deadline(error: &io::Error) -> bool {
    if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) {
        return true;
    }
    let mut source: Option<&(dyn Error + 'static)> =
        error.get_ref().map(|inner| inner as &(dyn Error + 'static));
    while let Some(inner) = source {
        if inner.is::<DeadlineExceeded>() {
            return true;
        }
        if let Some(io) = inner.downcast_ref::<io::Error>()
            && matches!(io.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock)
        {
            return true;
        }
        source = inner.source();
    }
    false
}

fn exceeded() -> io::Error {
    io::Error::new(ErrorKind::TimedOut, DeadlineExceeded)
}

/// A stream whose reads and writes all end by one absolute deadline.
pub trait TimeoutStream: Read + Write {
    /// `set_read_timeout` (a `Some` duration is never zero).
    fn set_read_limit(&self, timeout: Option<Duration>) -> io::Result<()>;
    /// `set_write_timeout` (a `Some` duration is never zero).
    fn set_write_limit(&self, timeout: Option<Duration>) -> io::Result<()>;
}

impl TimeoutStream for TcpStream {
    fn set_read_limit(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_read_timeout(timeout)
    }
    fn set_write_limit(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_write_timeout(timeout)
    }
}

#[cfg(unix)]
impl TimeoutStream for std::os::unix::net::UnixStream {
    fn set_read_limit(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_read_timeout(timeout)
    }
    fn set_write_limit(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.set_write_timeout(timeout)
    }
}

/// `inner` with every read and write bounded by an absolute deadline (see
/// the module docs). A timeout surfaces as `TimedOut` with
/// [`DeadlineExceeded`] inside, also when the socket itself timed out.
#[derive(Debug)]
pub struct DeadlineStream<S> {
    inner: S,
    deadline: Instant,
}

impl<S: TimeoutStream> DeadlineStream<S> {
    /// Wraps `inner`; all I/O must finish by `deadline`.
    pub fn new(inner: S, deadline: Instant) -> Self {
        DeadlineStream { inner, deadline }
    }

    /// The current deadline.
    pub fn deadline(&self) -> Instant {
        self.deadline
    }

    /// Moves the deadline (e.g. a new phase of a long-lived connection).
    pub fn set_deadline(&mut self, deadline: Instant) {
        self.deadline = deadline;
    }

    /// The time left, or `DeadlineExceeded` once it has passed.
    pub fn remaining(&self) -> io::Result<Duration> {
        let left = self.deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            Err(exceeded())
        } else {
            Ok(left)
        }
    }

    /// The wrapped stream.
    pub fn get_ref(&self) -> &S {
        &self.inner
    }

    /// The wrapped stream (don't change its timeouts; they are re-armed
    /// before every call anyway).
    pub fn get_mut(&mut self) -> &mut S {
        &mut self.inner
    }

    /// The wrapped stream, with whatever socket timeout was last armed.
    pub fn into_inner(self) -> S {
        self.inner
    }

    fn finish<T>(&self, result: io::Result<T>) -> io::Result<T> {
        match result {
            Err(error) if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) => {
                Err(exceeded())
            }
            other => other,
        }
    }
}

impl<S: TimeoutStream> Read for DeadlineStream<S> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let left = self.remaining()?;
        self.inner.set_read_limit(Some(left))?;
        let result = self.inner.read(buf);
        self.finish(result)
    }
}

impl<S: TimeoutStream> Write for DeadlineStream<S> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let left = self.remaining()?;
        self.inner.set_write_limit(Some(left))?;
        let result = self.inner.write(buf);
        self.finish(result)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.remaining()?;
        let result = self.inner.flush();
        self.finish(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;
    use std::thread;

    /// A peer that sends one byte every `gap` for `count` bytes.
    fn trickler(count: usize, gap: Duration) -> (TcpStream, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            for _ in 0..count {
                if peer.write_all(b"x").is_err() {
                    return;
                }
                thread::sleep(gap);
            }
        });
        (TcpStream::connect(address).unwrap(), handle)
    }

    #[test]
    fn a_trickling_peer_cannot_outlast_the_deadline() {
        // Each byte arrives well within any per-read timeout; the whole
        // response would take 4 s. The deadline is 300 ms.
        let (tcp, peer) = trickler(80, Duration::from_millis(50));
        let started = Instant::now();
        let mut stream = DeadlineStream::new(tcp, started + Duration::from_millis(300));
        let mut data = Vec::new();
        let error = stream.read_to_end(&mut data).unwrap_err();
        let took = started.elapsed();
        assert_eq!(error.kind(), ErrorKind::TimedOut);
        assert!(is_deadline(&error));
        assert!(error.get_ref().unwrap().is::<DeadlineExceeded>());
        assert!(took < Duration::from_millis(900), "took {took:?}");
        assert!(!data.is_empty() && data.len() < 80);
        drop(stream);
        peer.join().unwrap();
    }

    #[test]
    fn layered_readers_are_bounded_too() {
        // A line reader on top (as an HTTP head parser would be): no newline
        // ever comes, and the deadline still ends it.
        let (tcp, peer) = trickler(60, Duration::from_millis(20));
        let started = Instant::now();
        let mut reader = BufReader::new(DeadlineStream::new(
            tcp,
            started + Duration::from_millis(200),
        ));
        let mut line = String::new();
        let error = reader.read_line(&mut line).unwrap_err();
        assert!(is_deadline(&error));
        assert!(started.elapsed() < Duration::from_millis(800));
        drop(reader);
        peer.join().unwrap();
    }

    #[test]
    fn a_past_deadline_fails_without_io_and_can_be_moved() {
        let (tcp, peer) = trickler(1, Duration::ZERO);
        let mut stream = DeadlineStream::new(tcp, Instant::now());
        let mut byte = [0u8; 1];
        assert!(is_deadline(&stream.read(&mut byte).unwrap_err()));
        assert!(is_deadline(&stream.write(b"x").unwrap_err()));
        stream.set_deadline(Instant::now() + Duration::from_secs(5));
        assert_eq!(stream.read(&mut byte).unwrap(), 1);
        assert_eq!(&byte, b"x");
        peer.join().unwrap();
    }

    #[test]
    fn wrapped_errors_are_recognised() {
        let inner = io::Error::new(ErrorKind::TimedOut, DeadlineExceeded);
        let wrapped = io::Error::other(inner);
        assert!(is_deadline(&wrapped));
        assert!(!is_deadline(&io::Error::other("refused")));
    }
}
