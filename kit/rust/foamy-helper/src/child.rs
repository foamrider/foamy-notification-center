// foamy-kit 0.8.1 c63dc35ac197c621d9f2541be5c00fbafe38fb4f5c133ee57ffe19e3c7421f41 — do not edit; change foamy-kit and run sync
//! Bounded child processes: a deadline, a cap on captured output, a kill on
//! either, and control over the environment, standard input, the process
//! group or session, resource limits, CPU and I/O priority and death with
//! the parent. Two of them can run as a [`Pipeline`]: the first one's
//! standard output into the second one's standard input, counted.
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
use std::fs::File;
use std::io::{self, ErrorKind, Read, Write};
use std::ops::ControlFlow;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::fs::{OFlags, fcntl_getfl, fcntl_setfl};
use rustix::io::Errno;
use rustix::pipe::{SpliceFlags, fcntl_setpipe_size, splice};
use rustix::process::{Pid, Signal, getpid, kill_process_group};

use crate::process::{Priority, Resource};

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

/// Where the child's standard input comes from.
#[derive(Debug)]
enum Input {
    /// `/dev/null`.
    Null,
    /// These bytes, through a pipe.
    Bytes(Vec<u8>),
    /// An open file (or any fd), handed over as fd 0.
    Fd(OwnedFd),
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
    stdin: Input,
    die_with_parent: bool,
    group: Group,
    limits: Vec<(Resource, u64)>,
    priority: Priority,
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
            stdin: Input::Null,
            die_with_parent: true,
            group: Group::Own,
            limits: Vec::new(),
            priority: Priority::default(),
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
    /// Replaces an earlier [`stdin_fd`](Self::stdin_fd).
    pub fn stdin(mut self, data: impl Into<Vec<u8>>) -> Bounded {
        self.stdin = Input::Bytes(data.into());
        self
    }

    /// Standard input straight from `fd` (a [`File`] the helper opened and
    /// checked, say): the child gets it as fd 0 and reads from its current
    /// offset. A regular file stays seekable (ffmpeg can read an MP4 whose
    /// index is at the end), and nothing is copied through this process.
    /// The child shares the open file description, offset included, with
    /// any duplicate the caller keeps. Replaces an earlier
    /// [`stdin`](Self::stdin).
    pub fn stdin_fd(mut self, fd: impl Into<OwnedFd>) -> Bounded {
        self.stdin = Input::Fd(fd.into());
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

    /// Runs the child at niceness `niceness` (`nice -n`; 19 is the lowest
    /// CPU priority), or at its inherited niceness when that is already
    /// higher (raising it needs no privilege, lowering it would). Its
    /// threads and children inherit it.
    pub fn nice(mut self, niceness: i32) -> Bounded {
        self.priority.nice = Some(niceness);
        self
    }

    /// Runs the child in the idle I/O scheduling class (`ionice -c 3`): it
    /// gets disk time only when nothing else wants it. Its threads and
    /// children inherit it. With [`nice(19)`](Self::nice), a background job
    /// that keeps the desktop responsive.
    pub fn io_idle(mut self) -> Bounded {
        self.priority.io_idle = true;
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
    /// session, death signal, rlimits, priority and inherited fds.
    #[cfg_attr(not(feature = "sandbox"), allow(dead_code))]
    pub(crate) fn pre_exec_hook(mut self, hook: Hook) -> Bounded {
        self.hooks.0.push(hook);
        self
    }

    /// A [`Pipeline`]: this child's standard output into `next`'s standard
    /// input.
    pub fn pipe_into(self, next: Bounded) -> Pipeline {
        Pipeline {
            first: self,
            second: next,
        }
    }

    /// Runs the child to completion within the bounds. `Err` only when it
    /// could not be started or waited for; a timeout or an overflow is an
    /// [`Output`] with `timed_out` or `overflowed` set.
    pub fn run(self) -> io::Result<Output> {
        let started = Instant::now();
        let child = self.start(Stdin::Own)?;
        let mut run = Run::new(started + child.timeout, None);
        run.add(child)?;
        Ok(run.finish()?.outputs.remove(0))
    }

    /// Spawns the child (`stdin`: its own input, or a pipe for a pipeline).
    fn start(self, stdin: Stdin) -> io::Result<Started> {
        let Bounded {
            mut command,
            timeout,
            max_output,
            stdin: input,
            die_with_parent,
            group,
            limits,
            priority,
            inherit,
            hooks,
        } = self;
        let feed = match (stdin, input) {
            (Stdin::Pipe, _) => {
                command.stdin(Stdio::piped());
                None
            }
            (Stdin::Own, Input::Null) => {
                command.stdin(Stdio::null());
                None
            }
            (Stdin::Own, Input::Bytes(data)) => {
                command.stdin(Stdio::piped());
                Some(data)
            }
            (Stdin::Own, Input::Fd(fd)) => {
                command.stdin(Stdio::from(fd));
                None
            }
        };
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        if group == Group::Own {
            command.process_group(0);
        }
        let session = group == Group::Session;
        let parent = die_with_parent.then(getpid);
        // SAFETY: the closure runs in the forked child before exec. It only
        // makes system calls through rustix (setsid, prctl, getppid,
        // getrlimit, setrlimit, getpriority, setpriority, fcntl) and libc's
        // syscall (ioprio_set), and builds io::Errors from raw OS codes, so
        // it neither allocates nor takes locks; `limits` and `inherit` are
        // moved in and only read. The hooks are the crate's own (sandbox),
        // which hold to the same rule.
        unsafe {
            command.pre_exec(move || {
                crate::process::child_setup(session, parent, &limits, priority)?;
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
        let mut child = command.spawn()?;
        Ok(Started {
            stdin: child.stdin.take(),
            stdout: child.stdout.take().map(OwnedFd::from),
            stderr: child.stderr.take().map(OwnedFd::from),
            feed,
            timeout,
            stage: Stage {
                child,
                status: None,
                out: Vec::new(),
                err: Vec::new(),
                cap: max_output,
                timed_out: false,
                overflowed: false,
            },
        })
    }
}

/// Two bounded children, the first one's standard output piped into the
/// second one's standard input through this process, which counts the
/// bytes (moved with `splice`, not copied). Build it with
/// [`Bounded::pipe_into`]; each stage keeps its own environment, limits,
/// priority, sandbox and output cap.
///
/// - **Deadline:** the shorter of the two stages' timeouts, from the start.
///   When it passes, both are killed (each still running reports
///   `timed_out`).
/// - **Output:** the first stage's standard error and the second stage's
///   standard output and error are captured, each up to its stage's
///   `max_output`; more kills both. The piped bytes are not capped:
///   [`run_with_progress`](Self::run_with_progress) can stop at a count.
/// - **Input:** the first stage's [`stdin`](Bounded::stdin) or
///   [`stdin_fd`](Bounded::stdin_fd) as set; the second stage's is the pipe
///   (setting one is `InvalidInput`).
/// - **Ends:** when the first stage closes its output, the second stage
///   reads end-of-file; when the second stage stops reading, the first one
///   gets `EPIPE` (or `SIGPIPE`) on its next write.
/// - **Cancel and errors:** both stages are killed, process groups
///   included, and always waited for, so nothing is left running or as a
///   zombie.
///
/// ```no_run
/// use std::ops::ControlFlow;
/// use std::time::Duration;
/// use foamy_helper::child::Bounded;
/// # fn main() -> std::io::Result<()> {
/// let frame = 1920 * 1080 * 3 / 2; // one yuv420p frame
/// let decode = Bounded::new("ffmpeg")
///     .args(["-fd", "0", "-i", "fd:"]) // fd: seeks, pipe: would not
///     .args(["-f", "rawvideo", "-pix_fmt", "yuv420p", "pipe:1"])
///     .stdin_fd(std::fs::File::open("input.mp4")?)
///     .nice(19)
///     .io_idle()
///     .timeout(Duration::from_secs(600));
/// let encode = Bounded::new("ffmpeg")
///     .args(["-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", "1920x1080"])
///     .args(["-i", "pipe:0", "-f", "mp4", "-movflags", "+frag_keyframe+empty_moov", "pipe:1"])
///     .nice(19)
///     .io_idle()
///     .max_output(150 << 20)
///     .timeout(Duration::from_secs(600));
/// let output = decode.pipe_into(encode).run_with_progress(|bytes| {
///     println!("{} frames", bytes / frame);
///     ControlFlow::Continue(())
/// })?;
/// if output.success() { /* output.second.stdout is the MP4 */ }
/// # Ok(()) }
/// ```
#[derive(Debug)]
pub struct Pipeline {
    first: Bounded,
    second: Bounded,
}

/// What a [`Pipeline`] left behind.
#[derive(Debug)]
pub struct PipelineOutput {
    /// The first stage (its `stdout` is empty: that went to the second).
    pub first: Output,
    /// The second stage.
    pub second: Output,
    /// Bytes moved from the first stage to the second.
    pub piped: u64,
    /// Both were killed because the progress callback said stop.
    pub cancelled: bool,
}

impl PipelineOutput {
    /// Both stages exited with status 0 on their own (no timeout, overflow
    /// or cancel).
    pub fn success(&self) -> bool {
        self.first.success() && self.second.success() && !self.cancelled
    }
}

/// How often [`Pipeline::run_with_progress`] calls back when no bytes move.
const TICK: Duration = Duration::from_millis(100);

/// The pipe buffers between the stages (pipe-max-size's default): fewer
/// wake-ups for large frames. A smaller pipe still works.
const PIPE_SIZE: usize = 1 << 20;

impl Pipeline {
    /// Runs both stages to completion within the bounds (see [`Pipeline`]).
    /// `Err` only when a stage could not be started or waited for.
    pub fn run(self) -> io::Result<PipelineOutput> {
        self.go(None)
    }

    /// [`run`](Self::run), calling `progress` with the bytes piped so far
    /// after every transfer and at least every 100 ms while nothing moves.
    /// Returning `ControlFlow::Break(())` cancels: both stages are killed
    /// and waited for, and the output has `cancelled` set. Count frames
    /// with it, stop at a byte limit, or check a cancel flag that a signal
    /// handler sets.
    pub fn run_with_progress(
        self,
        mut progress: impl FnMut(u64) -> ControlFlow<()>,
    ) -> io::Result<PipelineOutput> {
        self.go(Some(&mut progress))
    }

    fn go(
        self,
        progress: Option<&mut dyn FnMut(u64) -> ControlFlow<()>>,
    ) -> io::Result<PipelineOutput> {
        let Pipeline { first, second } = self;
        if !matches!(second.stdin, Input::Null) {
            return Err(io::Error::new(
                ErrorKind::InvalidInput,
                "the second stage of a pipeline reads the first one's output",
            ));
        }
        let started = Instant::now();
        let mut first = first.start(Stdin::Own)?;
        // If the second can't start, dropping `first` kills and reaps it
        // (Stage's Drop).
        let mut second = second.start(Stdin::Pipe)?;
        let deadline = started + first.timeout.min(second.timeout);
        let (Some(from), Some(to)) = (first.stdout.take(), second.stdin.take()) else {
            return Err(io::Error::other("pipeline stages without pipes"));
        };
        let _ = fcntl_setpipe_size(&from, PIPE_SIZE);
        let _ = fcntl_setpipe_size(&to, PIPE_SIZE);
        let mut run = Run::new(deadline, progress);
        run.streams.push(Stream::Relay {
            from,
            to: OwnedFd::from(to),
            wait_out: false,
        });
        run.add(first)?;
        run.add(second)?;
        let Finished {
            mut outputs,
            cancelled,
            piped,
        } = run.finish()?;
        let second = outputs.pop().expect("two stages");
        let first = outputs.pop().expect("two stages");
        Ok(PipelineOutput {
            first,
            second,
            piped,
            cancelled,
        })
    }
}

/// A child's standard input: its own setting, or a pipe from us.
#[derive(Clone, Copy)]
enum Stdin {
    Own,
    Pipe,
}

/// A spawned child with the ends of its pipes.
struct Started {
    stage: Stage,
    stdin: Option<ChildStdin>,
    stdout: Option<OwnedFd>,
    stderr: Option<OwnedFd>,
    feed: Option<Vec<u8>>,
    timeout: Duration,
}

/// A running (or reaped) child and what it wrote.
struct Stage {
    child: Child,
    status: Option<ExitStatus>,
    out: Vec<u8>,
    err: Vec<u8>,
    cap: usize,
    timed_out: bool,
    overflowed: bool,
}

impl Stage {
    fn kill(&mut self) {
        // Never after the child was reaped: its pid (and group id) may
        // belong to someone else by then.
        if self.status.is_none() {
            kill(&mut self.child);
        }
    }

    fn reap(&mut self) -> io::Result<ExitStatus> {
        match self.status {
            Some(status) => Ok(status),
            None => {
                let status = self.child.wait()?;
                self.status = Some(status);
                Ok(status)
            }
        }
    }
}

impl Drop for Stage {
    /// An error or a panic on the way: kill and reap, never leave a running
    /// child or a zombie behind.
    fn drop(&mut self) {
        if self.status.is_none() {
            kill(&mut self.child);
            let _ = self.child.wait();
        }
    }
}

fn set_nonblocking(pipe: &impl AsFd) -> io::Result<()> {
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

/// A pipe this process services.
enum Stream {
    /// A child's output into its stage's buffer.
    Capture {
        pipe: File,
        stage: usize,
        stdout: bool,
    },
    /// Bytes into a child's standard input.
    Feed {
        pipe: ChildStdin,
        data: Vec<u8>,
        written: usize,
    },
    /// One child's standard output into another's standard input.
    Relay {
        from: OwnedFd,
        to: OwnedFd,
        /// The last splice found `to` full: wait until it takes more.
        wait_out: bool,
    },
}

/// What servicing a stream led to.
enum Step {
    Keep,
    Close,
    Overflowed(usize),
    Cancelled,
}

/// A run's result: the outputs in stage order.
struct Finished {
    outputs: Vec<Output>,
    cancelled: bool,
    piped: u64,
}

/// How a run ended.
enum End {
    Done,
    TimedOut,
    Overflowed(usize),
    Cancelled,
}

/// The children of one run, their pipes and the bounds.
struct Run<'p> {
    stages: Vec<Stage>,
    streams: Vec<Stream>,
    deadline: Instant,
    piped: u64,
    progress: Option<&'p mut dyn FnMut(u64) -> ControlFlow<()>>,
    next_tick: Instant,
}

/// Appends a read to `buffer`; true when that went over `cap` (the excess
/// is dropped).
fn keep(buffer: &mut Vec<u8>, data: &[u8], cap: usize) -> bool {
    let room = cap.saturating_sub(buffer.len());
    buffer.extend_from_slice(&data[..data.len().min(room)]);
    data.len() > room
}

impl<'p> Run<'p> {
    fn new(
        deadline: Instant,
        progress: Option<&'p mut dyn FnMut(u64) -> ControlFlow<()>>,
    ) -> Run<'p> {
        Run {
            stages: Vec::new(),
            streams: Vec::new(),
            deadline,
            piped: 0,
            progress,
            next_tick: Instant::now() + TICK,
        }
    }

    /// Takes over a started child: its output is captured and its input
    /// (if it has bytes for it) fed.
    fn add(&mut self, started: Started) -> io::Result<()> {
        let index = self.stages.len();
        let Started {
            stage,
            stdin,
            stdout,
            stderr,
            feed,
            ..
        } = started;
        self.stages.push(stage);
        for (pipe, stdout) in [(stdout, true), (stderr, false)] {
            if let Some(pipe) = pipe {
                self.streams.push(Stream::Capture {
                    pipe: File::from(pipe),
                    stage: index,
                    stdout,
                });
            }
        }
        if let (Some(pipe), Some(data)) = (stdin, feed) {
            set_nonblocking(&pipe)?;
            self.streams.push(Stream::Feed {
                pipe,
                data,
                written: 0,
            });
        }
        Ok(())
    }

    /// Runs to the end and reaps every child.
    fn finish(mut self) -> io::Result<Finished> {
        let end = self.drive()?;
        let mut cancelled = false;
        match end {
            End::Done => {}
            End::TimedOut => {
                for stage in &mut self.stages {
                    if stage.status.is_none() {
                        stage.timed_out = true;
                    }
                }
            }
            End::Overflowed(index) => self.stages[index].overflowed = true,
            End::Cancelled => cancelled = true,
        }
        if !matches!(end, End::Done) {
            for stage in &mut self.stages {
                stage.kill();
            }
        }
        // Only then close our pipe ends: closed first, the second stage of
        // a pipeline would read end-of-file and could exit 0 with half the
        // data before the kill.
        self.streams.clear();
        let mut outputs = Vec::with_capacity(self.stages.len());
        for stage in &mut self.stages {
            let status = stage.reap()?;
            outputs.push(Output {
                status,
                stdout: std::mem::take(&mut stage.out),
                stderr: std::mem::take(&mut stage.err),
                timed_out: stage.timed_out,
                overflowed: stage.overflowed,
            });
        }
        Ok(Finished {
            outputs,
            cancelled,
            piped: self.piped,
        })
    }

    /// Calls the progress callback when a tick is due; true to cancel.
    fn tick(&mut self, now: Instant) -> bool {
        let Some(progress) = self.progress.as_mut() else {
            return false;
        };
        if now < self.next_tick {
            return false;
        }
        self.next_tick = now + TICK;
        progress(self.piped).is_break()
    }

    /// Moves bytes until every pipe is closed (outputs at EOF, inputs fully
    /// written or no longer read), then waits for the children, all within
    /// the deadline. A child that closes or redirects its output before
    /// reading its input still gets all of it.
    fn drive(&mut self) -> io::Result<End> {
        let mut chunk = vec![0u8; 16 * 1024];
        while !self.streams.is_empty() {
            let now = Instant::now();
            if now >= self.deadline {
                return Ok(End::TimedOut);
            }
            if self.tick(now) {
                return Ok(End::Cancelled);
            }
            let mut left = self.deadline - now;
            if self.progress.is_some() {
                left = left.min(self.next_tick.saturating_duration_since(now));
            }
            let ready = match self.poll(left) {
                Ok(ready) => ready,
                Err(Errno::INTR) => continue,
                Err(error) => return Err(error.into()),
            };
            // Back to front, so removing one keeps the others' indices.
            for index in (0..self.streams.len()).rev() {
                if !ready[index] {
                    continue;
                }
                match self.service(index, &mut chunk)? {
                    Step::Keep => {}
                    Step::Close => {
                        self.streams.remove(index);
                    }
                    Step::Overflowed(stage) => return Ok(End::Overflowed(stage)),
                    Step::Cancelled => return Ok(End::Cancelled),
                }
            }
        }
        loop {
            for stage in &mut self.stages {
                if stage.status.is_none() {
                    stage.status = stage.child.try_wait()?;
                }
            }
            if self.stages.iter().all(|stage| stage.status.is_some()) {
                return Ok(End::Done);
            }
            let now = Instant::now();
            if now >= self.deadline {
                return Ok(End::TimedOut);
            }
            if self.tick(now) {
                return Ok(End::Cancelled);
            }
            thread::sleep((self.deadline - now).min(Duration::from_millis(5)));
        }
    }

    /// Polls every stream (at most `left`); which ones are ready.
    fn poll(&self, left: Duration) -> Result<Vec<bool>, Errno> {
        let wait = Timespec {
            tv_sec: left.as_secs() as _,
            tv_nsec: left.subsec_nanos() as _,
        };
        let mut polled: Vec<PollFd<'_>> = self
            .streams
            .iter()
            .map(|stream| match stream {
                Stream::Capture { pipe, .. } => PollFd::new(pipe, PollFlags::IN),
                Stream::Feed { pipe, .. } => PollFd::new(pipe, PollFlags::OUT),
                Stream::Relay {
                    to, wait_out: true, ..
                } => PollFd::new(to, PollFlags::OUT),
                Stream::Relay { from, .. } => PollFd::new(from, PollFlags::IN),
            })
            .collect();
        poll(&mut polled, Some(&wait))?;
        Ok(polled
            .iter()
            .map(|fd| {
                fd.revents()
                    .intersects(PollFlags::IN | PollFlags::OUT | PollFlags::HUP | PollFlags::ERR)
            })
            .collect())
    }

    /// Services a stream that poll reported ready.
    fn service(&mut self, index: usize, chunk: &mut [u8]) -> io::Result<Step> {
        match &mut self.streams[index] {
            Stream::Capture {
                pipe,
                stage,
                stdout,
            } => match pipe.read(chunk) {
                Ok(0) => Ok(Step::Close),
                Ok(n) => {
                    let stage_index = *stage;
                    let stage = &mut self.stages[stage_index];
                    let buffer = if *stdout {
                        &mut stage.out
                    } else {
                        &mut stage.err
                    };
                    if keep(buffer, &chunk[..n], stage.cap) {
                        return Ok(Step::Overflowed(stage_index));
                    }
                    Ok(Step::Keep)
                }
                Err(error)
                    if matches!(error.kind(), ErrorKind::Interrupted | ErrorKind::WouldBlock) =>
                {
                    Ok(Step::Keep)
                }
                Err(error) => Err(error),
            },
            Stream::Feed {
                pipe,
                data,
                written,
            } => {
                // Writes what the pipe takes; closes it when done or when
                // the child stopped reading.
                while *written < data.len() {
                    match pipe.write(&data[*written..]) {
                        Ok(n) => *written += n,
                        Err(error) if error.kind() == ErrorKind::WouldBlock => {
                            return Ok(Step::Keep);
                        }
                        Err(error) if error.kind() == ErrorKind::Interrupted => {}
                        Err(error) if error.kind() == ErrorKind::BrokenPipe => break,
                        Err(error) => return Err(error),
                    }
                }
                Ok(Step::Close)
            }
            Stream::Relay {
                wait_out: wait @ true,
                ..
            } => {
                *wait = false;
                Ok(Step::Keep)
            }
            Stream::Relay { from, to, wait_out } => {
                let flags = SpliceFlags::NONBLOCK | SpliceFlags::MOVE;
                match splice(&*from, None, &*to, None, PIPE_SIZE, flags) {
                    // The first stage closed its output: the second reads EOF.
                    Ok(0) => Ok(Step::Close),
                    Ok(n) => {
                        self.piped += n as u64;
                        let stop = self
                            .progress
                            .as_mut()
                            .is_some_and(|progress| progress(self.piped).is_break());
                        Ok(if stop { Step::Cancelled } else { Step::Keep })
                    }
                    // `to` is full (`from` was readable): wait for room.
                    Err(Errno::AGAIN) => {
                        *wait_out = true;
                        Ok(Step::Keep)
                    }
                    // The second stage stopped reading.
                    Err(Errno::PIPE) => Ok(Step::Close),
                    Err(Errno::INTR) => Ok(Step::Keep),
                    Err(error) => Err(error.into()),
                }
            }
        }
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

    use std::io::{Seek, SeekFrom};
    use std::os::unix::process::ExitStatusExt;

    #[test]
    fn stdin_fd_hands_over_a_seekable_file_at_its_offset() {
        let dir = crate::fs::tests::TempDir::new("stdin-fd");
        let path = dir.0.join("input");
        std::fs::write(&path, b"0123456789").unwrap();
        let mut file = File::open(&path).unwrap();
        file.seek(SeekFrom::Start(4)).unwrap();
        let keep = file.try_clone().unwrap();
        let output = sh("[ -f /dev/stdin ] && echo regular; cat")
            .stdin_fd(file)
            .run()
            .unwrap();
        assert!(output.success(), "{output:?}");
        assert_eq!(output.stdout_lossy(), "regular\n456789");
        let mut keep = keep;
        assert_eq!(
            keep.stream_position().unwrap(),
            10,
            "the offset is shared with the caller's duplicate"
        );
        // The last stdin setting wins.
        let replaced = sh("cat")
            .stdin_fd(File::open(&path).unwrap())
            .stdin("bytes")
            .run()
            .unwrap();
        assert_eq!(replaced.stdout, b"bytes");
        let replaced = sh("cat")
            .stdin("bytes")
            .stdin_fd(File::open(&path).unwrap())
            .run()
            .unwrap();
        assert_eq!(replaced.stdout, b"0123456789");
    }

    /// The niceness of the process running `script` (field 19 of its stat).
    const NICENESS: &str = "cut -d' ' -f19 /proc/$$/stat";

    #[test]
    fn nice_and_io_idle_apply_to_the_child_only() {
        let own = rustix::process::getpriority_process(None).unwrap();
        let script = format!("{NICENESS}; command -v ionice >/dev/null && ionice -p $$");
        let idle = sh(&script).nice(19).io_idle().run().unwrap();
        assert!(idle.success(), "{idle:?}");
        let lines: Vec<String> = idle.stdout_lossy().lines().map(str::to_string).collect();
        assert_eq!(lines[0], "19");
        if lines.len() > 1 {
            assert_eq!(lines[1], "idle", "{lines:?}");
        } else {
            eprintln!("SKIP io_idle check: no ionice");
        }
        // Its children inherit both.
        let child = sh(&format!("sh -c \"{}\"", script.replace('$', "\\$")))
            .nice(19)
            .io_idle()
            .run()
            .unwrap();
        assert_eq!(child.stdout, idle.stdout);
        // A niceness below the inherited one keeps the inherited one (no
        // privilege needed, no error).
        let lower = sh(NICENESS).nice(own - 5).run().unwrap();
        assert!(lower.success(), "{lower:?}");
        assert_eq!(lower.stdout_lossy().trim(), own.to_string());
        let plain = sh(&script).run().unwrap();
        assert_eq!(plain.stdout_lossy().lines().next(), Some(&*own.to_string()));
        assert_ne!(plain.stdout_lossy().lines().nth(1), Some("idle"));
    }

    /// The pids a test script wrote to `path`, one per line.
    fn pids(path: &Path) -> Vec<String> {
        let text = std::fs::read_to_string(path).unwrap();
        let pids: Vec<String> = text.lines().map(str::to_string).collect();
        assert!(
            pids.iter().all(|pid| pid.parse::<u32>().is_ok()),
            "{pids:?}"
        );
        pids
    }

    /// Whether `pid` is gone (exited and reaped).
    fn gone(pid: &str) -> bool {
        !Path::new(&format!("/proc/{pid}")).exists()
    }

    /// Whether `pid` is gone or a zombie someone else (init) must reap.
    fn not_running(pid: &str) -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
                Err(_) => return true,
                Ok(stat) if stat.rsplit(") ").next().is_some_and(|s| s.starts_with('Z')) => {
                    return true;
                }
                Ok(_) if Instant::now() > deadline => return false,
                Ok(_) => thread::sleep(Duration::from_millis(10)),
            }
        }
    }

    #[test]
    fn pipeline_counts_the_bytes_it_moves() {
        let mut seen = Vec::new();
        let output = sh("head -c 3000000 /dev/zero")
            .pipe_into(sh("wc -c"))
            .run_with_progress(|bytes| {
                seen.push(bytes);
                ControlFlow::Continue(())
            })
            .unwrap();
        assert!(output.success(), "{output:?}");
        assert_eq!(output.second.stdout_lossy().trim(), "3000000");
        assert_eq!(output.piped, 3_000_000);
        assert!(output.first.stdout.is_empty() && !output.cancelled);
        assert!(seen.windows(2).all(|w| w[0] <= w[1]), "{seen:?}");
        assert_eq!(seen.last(), Some(&3_000_000));
        // Without a callback; standard error of both stages is captured.
        let output = sh("printf abc; echo one >&2")
            .pipe_into(sh("cat; echo two >&2"))
            .run()
            .unwrap();
        assert!(output.success(), "{output:?}");
        assert_eq!(
            (&output.second.stdout[..], &output.first.stderr[..]),
            (&b"abc"[..], &b"one\n"[..])
        );
        assert_eq!(output.second.stderr, b"two\n");
        assert_eq!(output.piped, 3);
    }

    #[test]
    fn pipeline_first_stage_input_from_bytes_or_a_file() {
        let output = Bounded::new("cat")
            .stdin(vec![b'x'; 300_000])
            .pipe_into(Bounded::new("wc").arg("-c"))
            .run()
            .unwrap();
        assert_eq!(output.second.stdout_lossy().trim(), "300000");
        let dir = crate::fs::tests::TempDir::new("pipeline");
        let path = dir.0.join("input");
        std::fs::write(&path, b"from a file").unwrap();
        let output = sh("[ -f /dev/stdin ] && cat")
            .stdin_fd(File::open(&path).unwrap())
            .pipe_into(Bounded::new("cat"))
            .run()
            .unwrap();
        assert!(output.success(), "{output:?}");
        assert_eq!(output.second.stdout, b"from a file");
        // The second stage reads the pipe; any other input is refused
        // before anything starts.
        let error = sh("echo started >&2")
            .pipe_into(Bounded::new("cat").stdin("x"))
            .run()
            .unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
    }

    #[test]
    fn pipeline_ends_when_either_stage_stops() {
        // The second stops reading: the first gets SIGPIPE.
        let start = Instant::now();
        let output = Bounded::new("yes")
            .pipe_into(Bounded::new("head").args(["-c", "10"]))
            .run()
            .unwrap();
        assert!(output.second.success(), "{output:?}");
        assert_eq!(output.second.stdout, b"y\ny\ny\ny\ny\n");
        assert_eq!(output.first.status.signal(), Some(Signal::PIPE.as_raw()));
        assert!(!output.first.timed_out && start.elapsed() < Duration::from_secs(5));
        // The first fails: the second reads end-of-file.
        let output = sh("exit 3").pipe_into(sh("wc -c")).run().unwrap();
        assert_eq!(output.first.status.code(), Some(3));
        assert!(output.second.success() && !output.success());
        assert_eq!(output.second.stdout_lossy().trim(), "0");
    }

    #[test]
    fn pipeline_kills_both_at_the_deadline_and_leaves_no_zombies() {
        let dir = crate::fs::tests::TempDir::new("deadline");
        let (a, b) = (dir.0.join("a"), dir.0.join("b"));
        let start = Instant::now();
        let output = sh("echo $$ > \"$0\"; sleep 30 & echo $! >> \"$0\"; wait")
            .arg(&a)
            .timeout(Duration::from_secs(20))
            .pipe_into(
                sh("echo $$ > \"$0\"; exec cat")
                    .arg(&b)
                    .timeout(Duration::from_secs(1)),
            )
            .run()
            .unwrap();
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "the shorter timeout is the deadline: {:?}",
            start.elapsed()
        );
        assert!(
            output.first.timed_out && output.second.timed_out,
            "{output:?}"
        );
        assert!(!output.success());
        assert_eq!(output.first.status.signal(), Some(Signal::KILL.as_raw()));
        let (first, second) = (pids(&a), pids(&b));
        assert!(gone(&first[0]) && gone(&second[0]), "{first:?} {second:?}");
        assert!(not_running(&first[1]), "the grandchild was killed too");
    }

    #[test]
    fn pipeline_cancels_from_the_progress_callback() {
        let dir = crate::fs::tests::TempDir::new("cancel");
        let (a, b) = (dir.0.join("a"), dir.0.join("b"));
        let start = Instant::now();
        let output = sh("echo $$ > \"$0\"; exec yes")
            .arg(&a)
            .pipe_into(sh("echo $$ > \"$0\"; exec cat >/dev/null").arg(&b))
            .run_with_progress(|bytes| {
                // More than the pipe to the second stage holds: it has run.
                if bytes > 4_000_000 {
                    ControlFlow::Break(())
                } else {
                    ControlFlow::Continue(())
                }
            })
            .unwrap();
        assert!(output.cancelled && !output.success(), "{output:?}");
        assert!(output.piped > 4_000_000);
        assert!(!output.first.timed_out && !output.second.timed_out);
        for (stage, pid) in [(&output.first, &a), (&output.second, &b)] {
            assert_eq!(stage.status.signal(), Some(Signal::KILL.as_raw()));
            assert!(gone(&pids(pid)[0]));
        }
        // Also while nothing moves: the callback is called at least every
        // 100 ms.
        let mut calls = 0;
        let output = sh("sleep 30")
            .timeout(Duration::from_secs(20))
            .pipe_into(Bounded::new("cat").timeout(Duration::from_secs(20)))
            .run_with_progress(|bytes| {
                assert_eq!(bytes, 0);
                calls += 1;
                if calls == 3 {
                    ControlFlow::Break(())
                } else {
                    ControlFlow::Continue(())
                }
            })
            .unwrap();
        assert!(output.cancelled && calls == 3);
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "{:?}",
            start.elapsed()
        );
        // And after both closed their pipes but still run.
        let mut calls = 0;
        let output = sh("exec >&- 2>&-; sleep 30")
            .timeout(Duration::from_secs(20))
            .pipe_into(sh("exec >&- 2>&- <&-; sleep 30").timeout(Duration::from_secs(20)))
            .run_with_progress(|_| {
                calls += 1;
                if calls == 2 {
                    ControlFlow::Break(())
                } else {
                    ControlFlow::Continue(())
                }
            })
            .unwrap();
        assert!(output.cancelled, "{output:?}");
        assert!(start.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn pipeline_output_over_a_cap_kills_both() {
        let output = Bounded::new("yes")
            .pipe_into(Bounded::new("cat").max_output(1000))
            .run()
            .unwrap();
        assert!(output.second.overflowed && !output.first.overflowed);
        assert_eq!(output.second.stdout.len(), 1000);
        assert!(!output.success() && !output.cancelled);
        let output = sh("yes >&2")
            .max_output(500)
            .pipe_into(Bounded::new("cat"))
            .run()
            .unwrap();
        assert!(output.first.overflowed && output.first.stderr.len() == 500);
        assert!(!output.second.success(), "killed too: {output:?}");
    }

    #[test]
    fn pipeline_stages_keep_their_own_priority() {
        let own = rustix::process::getpriority_process(None).unwrap();
        let output = sh(NICENESS)
            .nice(19)
            .pipe_into(sh(&format!("cat; {NICENESS}")))
            .run()
            .unwrap();
        assert!(output.success(), "{output:?}");
        assert_eq!(output.second.stdout_lossy(), format!("19\n{own}\n"));
    }

    #[test]
    fn pipeline_whose_second_stage_cannot_start_kills_the_first() {
        let dir = crate::fs::tests::TempDir::new("spawn");
        let a = dir.0.join("a");
        let error = sh("echo $$ > \"$0\"; exec sleep 30")
            .arg(&a)
            .pipe_into(Bounded::new("/nonexistent/foamy"))
            .run()
            .unwrap_err();
        assert_eq!(error.kind(), ErrorKind::NotFound);
        // The first may not have written its pid before the kill.
        if a.exists() {
            assert!(gone(&pids(&a)[0]), "killed and reaped");
        }
    }
}
