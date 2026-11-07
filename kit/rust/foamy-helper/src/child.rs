// foamy-kit 0.5.1 c313f9ebfeef38e6adc56fb455e4643404b50f89aa495d7f7ffbaa139f40f351 — do not edit; change foamy-kit and run sync
//! Bounded child processes: a deadline, a cap on captured output, a kill on
//! either, and control over the environment, the process group or session,
//! resource limits and death with the parent.
//!
//! ```no_run
//! use std::time::Duration;
//! use foamy_helper::child::Bounded;
//! let output = Bounded::new("hyprctl")
//!     .args(["-j", "monitors"])
//!     .keep_env(&["PATH", "HOME", "XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE"])
//!     .timeout(Duration::from_secs(3))
//!     .max_output(1 << 20)
//!     .run()?;
//! if output.success() { /* parse output.stdout */ }
//! # Ok::<(), std::io::Error>(())
//! ```
//!
//! The same system tools the old helpers ran are run with the same argv;
//! this module only bounds them.

use std::ffi::OsStr;
use std::io::{self, ErrorKind, Read, Write};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::fs::{OFlags, fcntl_getfl, fcntl_setfl};
use rustix::io::Errno;
use rustix::process::{Pid, Signal, getpid, kill_process_group};

use crate::process::Resource;

/// What a bounded child left behind.
#[derive(Debug)]
pub struct Output {
    /// How it ended (after a kill: by `SIGKILL`).
    pub status: ExitStatus,
    /// Captured standard output, at most `max_output` bytes.
    pub stdout: Vec<u8>,
    /// Captured standard error, at most `max_output` bytes.
    pub stderr: Vec<u8>,
    /// Killed because the deadline passed.
    pub timed_out: bool,
    /// Killed because a stream exceeded `max_output`.
    pub overflowed: bool,
}

impl Output {
    /// Exited with status 0 on its own (no timeout, no overflow).
    pub fn success(&self) -> bool {
        self.status.success() && !self.timed_out && !self.overflowed
    }

    /// Standard output as text, invalid UTF-8 replaced.
    pub fn stdout_lossy(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }
}

/// A step run in the child between `fork` and `exec`, after the kit's own
/// setup. It must be async-signal-safe: system calls only, no allocation.
pub(crate) type Hook = Box<dyn Fn() -> io::Result<()> + Send + Sync>;

struct Hooks(Vec<Hook>);

impl std::fmt::Debug for Hooks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} pre-exec hook(s)", self.0.len())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Group {
    /// `setpgid(0, 0)`: its own process group, killed as a whole.
    Own,
    /// `setsid()`: its own session (and process group).
    Session,
}

/// A command with bounds; build it, then [`run`](Bounded::run) it.
///
/// Defaults: standard input `/dev/null`, 10 s deadline, 1 MiB per output
/// stream, its own process group (so a kill reaches its children too) and
/// `SIGKILL` when the thread that runs it exits.
#[derive(Debug)]
pub struct Bounded {
    command: Command,
    timeout: Duration,
    max_output: usize,
    stdin: Option<Vec<u8>>,
    die_with_parent: bool,
    group: Group,
    limits: Vec<(Resource, u64)>,
    inherit: Vec<RawFd>,
    hooks: Hooks,
}

impl Bounded {
    /// `program` is looked up in `PATH` like `Command::new`.
    pub fn new(program: impl AsRef<OsStr>) -> Bounded {
        Bounded {
            command: Command::new(program),
            timeout: Duration::from_secs(10),
            max_output: 1 << 20,
            stdin: None,
            die_with_parent: true,
            group: Group::Own,
            limits: Vec::new(),
            inherit: Vec::new(),
            hooks: Hooks(Vec::new()),
        }
    }

    /// Adds an argument.
    pub fn arg(mut self, arg: impl AsRef<OsStr>) -> Bounded {
        self.command.arg(arg);
        self
    }

    /// Adds arguments.
    pub fn args<I, S>(mut self, args: I) -> Bounded
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.command.args(args);
        self
    }

    /// Sets an environment variable.
    pub fn env(mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> Bounded {
        self.command.env(key, value);
        self
    }

    /// Removes an environment variable.
    pub fn env_remove(mut self, key: impl AsRef<OsStr>) -> Bounded {
        self.command.env_remove(key);
        self
    }

    /// Starts from an empty environment.
    pub fn env_clear(mut self) -> Bounded {
        self.command.env_clear();
        self
    }

    /// Starts from an empty environment plus those of `names` this process
    /// has. Call it before [`env`](Self::env).
    pub fn keep_env(mut self, names: &[&str]) -> Bounded {
        self.command.env_clear();
        for name in names {
            if let Some(value) = std::env::var_os(name) {
                self.command.env(name, value);
            }
        }
        self
    }

    /// Working directory of the child.
    pub fn current_dir(mut self, dir: impl AsRef<Path>) -> Bounded {
        self.command.current_dir(dir);
        self
    }

    /// Deadline for the whole run, from spawn to exit.
    pub fn timeout(mut self, timeout: Duration) -> Bounded {
        self.timeout = timeout;
        self
    }

    /// Cap per output stream in bytes; more kills the child.
    pub fn max_output(mut self, bytes: usize) -> Bounded {
        self.max_output = bytes;
        self
    }

    /// Bytes for standard input (written as the child reads; then closed).
    pub fn stdin(mut self, data: impl Into<Vec<u8>>) -> Bounded {
        self.stdin = Some(data.into());
        self
    }

    /// Whether the child gets `PR_SET_PDEATHSIG(SIGKILL)` (default true).
    pub fn die_with_parent(mut self, enabled: bool) -> Bounded {
        self.die_with_parent = enabled;
        self
    }

    /// Runs the child in a new session (`setsid`) instead of only a new
    /// process group.
    pub fn new_session(mut self) -> Bounded {
        self.group = Group::Session;
        self
    }

    /// Lowers a resource limit of the child (see [`crate::process::limit`]).
    pub fn rlimit(mut self, resource: Resource, value: u64) -> Bounded {
        self.limits.push((resource, value));
        self
    }

    /// Lets the child inherit `fd` under the same number (clears its
    /// close-on-exec flag in the child only), like Python's `pass_fds`. The
    /// fd must stay open until [`run`](Self::run).
    pub fn inherit_fd(self, fd: impl AsFd) -> Bounded {
        self.inherit_raw_fd(fd.as_fd().as_raw_fd())
    }

    pub(crate) fn inherit_raw_fd(mut self, fd: RawFd) -> Bounded {
        self.inherit.push(fd);
        self
    }

    /// Adds a step to run in the child just before `exec`, after the
    /// session, death signal, rlimits and inherited fds.
    #[cfg_attr(not(feature = "sandbox"), allow(dead_code))]
    pub(crate) fn pre_exec_hook(mut self, hook: Hook) -> Bounded {
        self.hooks.0.push(hook);
        self
    }

    /// Runs the child to completion within the bounds. `Err` only when it
    /// could not be started or waited for; a timeout or an overflow is an
    /// [`Output`] with `timed_out` or `overflowed` set.
    pub fn run(self) -> io::Result<Output> {
        let Bounded {
            mut command,
            timeout,
            max_output,
            stdin,
            die_with_parent,
            group,
            limits,
            inherit,
            hooks,
        } = self;
        command
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if group == Group::Own {
            command.process_group(0);
        }
        let session = group == Group::Session;
        let parent = die_with_parent.then(getpid);
        // SAFETY: the closure runs in the forked child before exec. It only
        // makes system calls through rustix (setsid, prctl, getppid,
        // getrlimit, setrlimit, fcntl) and builds io::Errors from raw OS
        // codes, so it neither allocates nor takes locks; `limits` and
        // `inherit` are moved in and only read. The hooks are the crate's
        // own (sandbox), which hold to the same rule.
        unsafe {
            command.pre_exec(move || {
                crate::process::child_setup(session, parent, &limits)?;
                for &fd in &inherit {
                    // SAFETY: only fcntl on the number; a closed fd is EBADF.
                    let fd = BorrowedFd::borrow_raw(fd);
                    rustix::io::fcntl_setfd(fd, rustix::io::FdFlags::empty())?;
                }
                for hook in &hooks.0 {
                    hook()?;
                }
                Ok(())
            });
        }
        let started = Instant::now();
        let mut child = command.spawn()?;
        let deadline = started + timeout;
        let mut streams = Streams {
            stdin: child.stdin.take(),
            pending: stdin.unwrap_or_default(),
            written: 0,
            stdout: child.stdout.take(),
            stderr: child.stderr.take(),
            out: Vec::new(),
            err: Vec::new(),
        };
        if let Some(pipe) = &streams.stdin
            && let Err(error) = set_nonblocking(pipe)
        {
            kill(&mut child);
            return Err(error);
        }
        let (mut timed_out, overflowed) = match streams.pump(deadline, max_output) {
            Ok(Pump::Done) => (false, false),
            Ok(Pump::TimedOut) => (true, false),
            Ok(Pump::Overflowed) => (false, true),
            Err(error) => {
                kill(&mut child);
                return Err(error);
            }
        };
        drop(streams.stdin.take());
        drop(streams.stdout.take());
        drop(streams.stderr.take());
        if timed_out || overflowed {
            kill(&mut child);
        }
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            let now = Instant::now();
            if now >= deadline {
                timed_out = true;
                kill(&mut child);
                break child.wait()?;
            }
            thread::sleep((deadline - now).min(Duration::from_millis(5)));
        };
        Ok(Output {
            status,
            stdout: streams.out,
            stderr: streams.err,
            timed_out,
            overflowed,
        })
    }
}

fn set_nonblocking(pipe: &ChildStdin) -> io::Result<()> {
    let flags = fcntl_getfl(pipe)?;
    fcntl_setfl(pipe, flags | OFlags::NONBLOCK)?;
    Ok(())
}

fn kill(child: &mut Child) {
    // The child leads its own process group (or session), so this also
    // reaches whatever it started; then the child itself, in case it
    // already left the group.
    let _ = kill_process_group(Pid::from_child(child), Signal::KILL);
    let _ = child.kill();
}

enum Pump {
    Done,
    TimedOut,
    Overflowed,
}

struct Streams {
    stdin: Option<ChildStdin>,
    pending: Vec<u8>,
    written: usize,
    stdout: Option<ChildStdout>,
    stderr: Option<ChildStderr>,
    out: Vec<u8>,
    err: Vec<u8>,
}

/// Appends a read to `buffer`; true when that went over `cap` (the excess
/// is dropped).
fn keep(buffer: &mut Vec<u8>, data: &[u8], cap: usize) -> bool {
    let room = cap.saturating_sub(buffer.len());
    buffer.extend_from_slice(&data[..data.len().min(room)]);
    data.len() > room
}

impl Streams {
    /// Moves bytes between the child and our buffers until both output
    /// streams end and standard input is fully written (or the child
    /// stopped reading it: `EPIPE`), the deadline passes or an output
    /// exceeds `cap`. A child that closes or redirects its output before
    /// reading its input still gets all of it.
    fn pump(&mut self, deadline: Instant, cap: usize) -> io::Result<Pump> {
        let mut chunk = vec![0u8; 16 * 1024];
        while self.stdout.is_some() || self.stderr.is_some() || self.stdin.is_some() {
            let now = Instant::now();
            if now >= deadline {
                return Ok(Pump::TimedOut);
            }
            let left = deadline - now;
            let wait = Timespec {
                tv_sec: left.as_secs() as _,
                tv_nsec: left.subsec_nanos() as _,
            };
            let (ready_out, ready_err, ready_in) = {
                let mut slots = Vec::with_capacity(3);
                let mut polled = Vec::with_capacity(3);
                if let Some(pipe) = &self.stdout {
                    slots.push(0);
                    polled.push(PollFd::from_borrowed_fd(pipe.as_fd(), PollFlags::IN));
                }
                if let Some(pipe) = &self.stderr {
                    slots.push(1);
                    polled.push(PollFd::from_borrowed_fd(pipe.as_fd(), PollFlags::IN));
                }
                if let Some(pipe) = &self.stdin {
                    slots.push(2);
                    polled.push(PollFd::from_borrowed_fd(pipe.as_fd(), PollFlags::OUT));
                }
                match poll(&mut polled, Some(&wait)) {
                    Ok(_) => {}
                    Err(Errno::INTR) => continue,
                    Err(error) => return Err(error.into()),
                }
                let mut ready = [false; 3];
                for (&slot, fd) in slots.iter().zip(&polled) {
                    let wanted = if slot == 2 {
                        PollFlags::OUT
                    } else {
                        PollFlags::IN
                    };
                    ready[slot] = fd
                        .revents()
                        .intersects(wanted | PollFlags::HUP | PollFlags::ERR);
                }
                (ready[0], ready[1], ready[2])
            };
            if ready_in {
                self.feed()?;
            }
            for (ready, is_out) in [(ready_out, true), (ready_err, false)] {
                if !ready {
                    continue;
                }
                let read = if is_out {
                    self.stdout.as_mut().map(|pipe| pipe.read(&mut chunk))
                } else {
                    self.stderr.as_mut().map(|pipe| pipe.read(&mut chunk))
                };
                match read {
                    None => {}
                    Some(Ok(0)) => {
                        if is_out {
                            self.stdout = None;
                        } else {
                            self.stderr = None;
                        }
                    }
                    Some(Ok(n)) => {
                        let buffer = if is_out { &mut self.out } else { &mut self.err };
                        if keep(buffer, &chunk[..n], cap) {
                            return Ok(Pump::Overflowed);
                        }
                    }
                    Some(Err(error)) if error.kind() == ErrorKind::Interrupted => {}
                    Some(Err(error)) => return Err(error),
                }
            }
        }
        Ok(Pump::Done)
    }

    /// Writes what the pipe takes; closes it when done or when the child
    /// stopped reading.
    fn feed(&mut self) -> io::Result<()> {
        let Some(pipe) = self.stdin.as_mut() else {
            return Ok(());
        };
        while self.written < self.pending.len() {
            match pipe.write(&self.pending[self.written..]) {
                Ok(n) => self.written += n,
                Err(error) if error.kind() == ErrorKind::WouldBlock => return Ok(()),
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(error) if error.kind() == ErrorKind::BrokenPipe => break,
                Err(error) => return Err(error),
            }
        }
        self.stdin = None;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> Bounded {
        Bounded::new("/bin/sh").arg("-c").arg(script)
    }

    #[test]
    fn captures_output_and_status() {
        let output = sh("printf out; printf err >&2; exit 3").run().unwrap();
        assert_eq!(
            (output.stdout.as_slice(), output.stderr.as_slice()),
            (&b"out"[..], &b"err"[..])
        );
        assert_eq!(output.status.code(), Some(3));
        assert!(!output.success() && !output.timed_out && !output.overflowed);
        assert!(sh("true").run().unwrap().success());
    }

    #[test]
    fn kills_at_the_deadline_including_grandchildren() {
        let start = Instant::now();
        let output = sh("sleep 30 & echo started; wait")
            .timeout(Duration::from_millis(200))
            .run()
            .unwrap();
        assert!(output.timed_out && !output.success());
        assert_eq!(output.stdout, b"started\n");
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "{:?}",
            start.elapsed()
        );
    }

    #[test]
    fn deadline_applies_after_the_child_closes_its_output() {
        let output = sh("exec >&- 2>&-; sleep 30")
            .timeout(Duration::from_millis(150))
            .run()
            .unwrap();
        assert!(output.timed_out);
    }

    #[test]
    fn output_over_the_cap_kills_the_child() {
        let output = sh("yes").max_output(1000).run().unwrap();
        assert!(output.overflowed && !output.timed_out && !output.success());
        assert_eq!(output.stdout.len(), 1000);
        let exact = sh("printf 12345").max_output(5).run().unwrap();
        assert!(exact.success() && exact.stdout == b"12345");
    }

    #[test]
    fn feeds_stdin_larger_than_a_pipe_buffer() {
        let data = vec![b'x'; 300_000];
        let output = Bounded::new("wc").arg("-c").stdin(data).run().unwrap();
        assert_eq!(output.stdout_lossy().trim(), "300000");
        // A child that never reads its input still finishes.
        let ignored = sh("exit 0").stdin(vec![0u8; 300_000]).run().unwrap();
        assert!(ignored.success());
        assert!(
            sh("cat").run().unwrap().stdout.is_empty(),
            "stdin defaults to /dev/null"
        );
    }

    #[test]
    fn keeps_feeding_stdin_after_the_child_closes_its_output() {
        // Regression (Codex review on PR #2): the input used to be cut off
        // once stdout and stderr had both closed.
        let dir = crate::fs::tests::TempDir::new("stdin");
        let target = dir.0.join("count");
        let output = sh("exec >&- 2>&-; wc -c > \"$0\"")
            .arg(&target)
            .stdin(vec![b'x'; 300_000])
            .run()
            .unwrap();
        assert!(output.success(), "{output:?}");
        assert_eq!(std::fs::read_to_string(&target).unwrap().trim(), "300000");
        // Closed output and a child that never reads: the deadline still holds.
        let start = Instant::now();
        let stuck = sh("exec >&- 2>&-; sleep 30")
            .stdin(vec![0u8; 300_000])
            .timeout(Duration::from_millis(200))
            .run()
            .unwrap();
        assert!(stuck.timed_out && start.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn controls_the_environment() {
        let output = sh("printf '%s|%s' \"${FOAMY_A-unset}\" \"${FOAMY_B-unset}\"")
            .keep_env(&["PATH"])
            .env("FOAMY_B", "b")
            .run()
            .unwrap();
        assert_eq!(output.stdout_lossy(), "unset|b");
        let empty = Bounded::new("/usr/bin/env").env_clear().run().unwrap();
        assert!(empty.success() && empty.stdout.is_empty());
    }

    #[test]
    fn isolates_the_process_group_or_session() {
        // Fields 5 and 6 of /proc/<pid>/stat: process group and session.
        let ids = "echo $$ $(cut -d' ' -f5,6 /proc/$$/stat)";
        let own = sh(ids).run().unwrap().stdout_lossy();
        let own: Vec<&str> = own.split_whitespace().collect();
        assert_eq!(own[0], own[1], "child leads its own process group");
        assert_ne!(own[0], own[2], "but not a session");
        let session = sh(ids).new_session().run().unwrap().stdout_lossy();
        let session: Vec<&str> = session.split_whitespace().collect();
        assert!(
            session[0] == session[1] && session[0] == session[2],
            "child leads its own session: {session:?}"
        );
    }

    #[test]
    fn applies_rlimits_and_reports_spawn_errors() {
        let output = sh("ulimit -n").rlimit(Resource::Nofile, 32).run().unwrap();
        assert_eq!(output.stdout_lossy().trim(), "32");
        assert!(Bounded::new("/nonexistent/foamy").run().is_err());
    }

    #[test]
    fn inherited_fds_reach_the_child_under_their_number() {
        let (read, mut write) = io::pipe().unwrap();
        write.write_all(b"through fd").unwrap();
        drop(write);
        let script = format!("cat <&{}", read.as_raw_fd());
        let output = sh(&script).inherit_fd(&read).run().unwrap();
        assert_eq!(output.stdout, b"through fd");
        let closed = sh(&script).run().unwrap();
        assert!(
            !closed.success(),
            "without inherit_fd the fd stays close-on-exec"
        );
    }

    #[test]
    fn keep_caps_appends() {
        let mut buffer = b"ab".to_vec();
        assert!(!keep(&mut buffer, b"cd", 4));
        assert!(keep(&mut buffer, b"e", 4));
        assert_eq!(buffer, b"abcd");
    }
}
