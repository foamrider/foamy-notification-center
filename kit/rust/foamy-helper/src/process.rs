// foamy-kit 0.8.1 0db730b49aa8ea779d896f40d055549a3090ec7c5d7915f1c48d101542d7eb46 — do not edit; change foamy-kit and run sync
//! This process: exiting on a panic, dying with the parent, a new session,
//! resource limits and the umask. Child processes get the same through
//! [`crate::child::Bounded`].

use std::io;
use std::panic::{self, PanicHookInfo};
use std::sync::OnceLock;

pub use rustix::process::Resource;
use rustix::process::{
    Rlimit, Signal, getppid, getpriority_process, getrlimit, set_parent_process_death_signal,
    setpriority_process, setrlimit, setsid,
};

type Hook = Box<dyn Fn(&PanicHookInfo<'_>) + Sync + Send + 'static>;

/// The hook that was installed before the kit's first one (normally std's
/// default, which reports the panic on standard error).
static REPORT: OnceLock<Hook> = OnceLock::new();

/// Installs the kit's panic hook: report the panic as before (std's message
/// on standard error, nothing on standard output), run `after`, then exit
/// with `code`. Replaces an earlier kit hook instead of chaining it, so
/// [`crate::json::run`] after [`exit_on_panic`] still prints its reply.
pub(crate) fn exit_on_panic_after(code: i32, after: impl Fn() + Send + Sync + 'static) {
    let report = REPORT.get_or_init(panic::take_hook);
    panic::set_hook(Box::new(move |info| {
        report(info);
        after();
        std::process::exit(code);
    }));
}

/// Makes a panic exit the process with `code` (the kit uses 101) instead of
/// aborting: the kit's release profile has `panic = "abort"`, which ends in
/// `SIGABRT` and a core dump. The panic message still goes to standard
/// error; standard output gets nothing, so a JSON-lines peer never sees a
/// torn reply. [`crate::json::run`] and [`crate::json::serve`] install it
/// themselves; **every helper that runs its own loop or protocol calls it
/// first thing in `main`**, before parsing arguments (read them with
/// `std::env::args_os()` afterwards: `std::env::args()` panics on non-UTF-8).
pub fn exit_on_panic(code: i32) {
    exit_on_panic_after(code, || {});
}

/// `PR_SET_PDEATHSIG(SIGKILL)`: the kernel kills this process when its
/// parent (the thread that started it) exits, so a helper never outlives
/// the shell that launched it. Fails if the parent changed while the signal
/// was being set (it exited in between). A parent that exited before this
/// call cannot be detected here (the helper was reparented already); call it
/// first thing in `main`.
pub fn die_with_parent() -> io::Result<()> {
    let parent = getppid();
    set_parent_process_death_signal(Some(Signal::KILL))?;
    if getppid() != parent {
        return Err(io::Error::other("the parent process exited"));
    }
    Ok(())
}

/// `setsid()`: this process leads a new session and process group, detached
/// from the caller's terminal and process-group signals. Fails (`EPERM`)
/// when the process already leads a process group.
pub fn new_session() -> io::Result<()> {
    setsid()?;
    Ok(())
}

/// The soft and hard limit actually set by [`limit`]: `value`, or the
/// current hard limit when that is lower (a limit can only be lowered).
fn bounded(resource: Resource, value: u64) -> Rlimit {
    let value = getrlimit(resource)
        .maximum
        .map_or(value, |hard| hard.min(value));
    Rlimit {
        current: Some(value),
        maximum: Some(value),
    }
}

/// Lowers both the soft and the hard limit of `resource` to `value` (or
/// keeps a lower hard limit), e.g. `limit(Resource::Core, 0)` for no core
/// dumps, `Resource::As` for address space, `Resource::Cpu` for seconds,
/// `Resource::Fsize` for the largest file, `Resource::Nofile` for open files.
/// The hard limit cannot be raised again.
pub fn limit(resource: Resource, value: u64) -> io::Result<()> {
    setrlimit(resource, bounded(resource, value))?;
    Ok(())
}

/// Sets the umask and returns the previous one, e.g. `set_umask(0o077)` so
/// new files and directories are private.
pub fn set_umask(mask: u32) -> u32 {
    rustix::process::umask(rustix::fs::Mode::from_raw_mode(mask & 0o777)).as_raw_mode()
}

/// CPU and I/O priority for a child ([`crate::child::Bounded::nice`] and
/// [`crate::child::Bounded::io_idle`]).
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct Priority {
    /// The niceness to raise to (a child already nicer keeps its own).
    pub(crate) nice: Option<i32>,
    /// The idle I/O scheduling class.
    pub(crate) io_idle: bool,
}

/// `ioprio_set`'s number: rustix has no wrapper, and libc is only a
/// dependency with some features. The numbers are fixed ABI.
#[cfg(target_arch = "x86_64")]
const SYS_IOPRIO_SET: std::ffi::c_long = 251;
#[cfg(target_arch = "aarch64")]
const SYS_IOPRIO_SET: std::ffi::c_long = 30;

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
unsafe extern "C" {
    /// The C library's `syscall(2)` (glibc and musl; std links either).
    fn syscall(number: std::ffi::c_long, ...) -> std::ffi::c_long;
}

/// `ioprio_set(IOPRIO_WHO_PROCESS, 0, IOPRIO_CLASS_IDLE << 13)`, what
/// `ionice -c 3` does: this process gets disk time only when no one else
/// wants it. Its threads and children inherit it. Async-signal-safe.
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn io_idle() -> io::Result<()> {
    const IOPRIO_WHO_PROCESS: std::ffi::c_long = 1;
    const IOPRIO_CLASS_IDLE: std::ffi::c_long = 3;
    const IOPRIO_CLASS_SHIFT: u32 = 13;
    // SAFETY: ioprio_set takes three integers (passed as longs, the
    // width `syscall` reads) and no pointers.
    let rc = unsafe {
        syscall(
            SYS_IOPRIO_SET,
            IOPRIO_WHO_PROCESS,
            0 as std::ffi::c_long,
            IOPRIO_CLASS_IDLE << IOPRIO_CLASS_SHIFT,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
fn io_idle() -> io::Result<()> {
    Err(io::Error::from_raw_os_error(
        rustix::io::Errno::NOSYS.raw_os_error(),
    ))
}

/// Child-side setup for [`crate::child::Bounded`]; runs between `fork` and
/// `exec`, so it only makes system calls (no allocation, no locks).
pub(crate) fn child_setup(
    session: bool,
    parent: Option<rustix::process::Pid>,
    limits: &[(Resource, u64)],
    priority: Priority,
) -> io::Result<()> {
    if session {
        setsid()?;
    }
    if let Some(parent) = parent {
        set_parent_process_death_signal(Some(Signal::KILL))?;
        if getppid() != Some(parent) {
            return Err(io::Error::from_raw_os_error(
                rustix::io::Errno::SRCH.raw_os_error(),
            ));
        }
    }
    for &(resource, value) in limits {
        setrlimit(resource, bounded(resource, value))?;
    }
    if let Some(nice) = priority.nice
        && nice > getpriority_process(None)?
    {
        // Raising the niceness needs no privilege; lowering it would.
        setpriority_process(None, nice)?;
    }
    if priority.io_idle {
        io_idle()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn umask_round_trips() {
        let previous = set_umask(0o077);
        assert_eq!(set_umask(previous), 0o077);
    }

    #[test]
    fn limits_never_exceed_the_hard_limit() {
        let hard = getrlimit(Resource::Nofile).maximum;
        let wanted = bounded(Resource::Nofile, u64::MAX);
        assert_eq!(wanted.maximum, Some(hard.unwrap_or(u64::MAX)));
        assert_eq!(bounded(Resource::Nofile, 3).current, Some(3));
    }

    #[cfg(any(feature = "sandbox", feature = "favicon"))]
    #[test]
    fn ioprio_set_has_the_number_libc_knows() {
        assert_eq!(SYS_IOPRIO_SET, libc::SYS_ioprio_set);
    }
}
