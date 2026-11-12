// foamy-kit 0.9.0 177670beb2ecd87d0f3dbcc74c67741990f779b2f1ccd15afce3f6f1893d318e — do not edit; change foamy-kit and run sync
//! Sandboxing for child processes (cargo feature `sandbox`): seccomp-BPF
//! filters ([`BpfFilter`], generated with `seccompiler`), a Landlock
//! restriction of what a child may execute ([`ExecOnly`], applied between
//! `fork` and `exec`), and bubblewrap command lines ([`Bwrap`]).
//!
//! They carry over the sandboxes of foamy-lock's `artwork.py` (an image
//! decoder in bubblewrap with a seccomp filter passed as `--seccomp <fd>`)
//! and foamy-github's `github_status.py` (Git under `setpriv
//! --landlock-access fs:execute`, and Git commands in a bubblewrap mount
//! namespace), with the same semantics:
//!
//! ```no_run
//! use std::time::Duration;
//! use foamy_helper::child::Bounded;
//! use foamy_helper::sandbox::{BpfFilter, Bwrap, ExecOnly};
//! # fn main() -> std::io::Result<()> {
//! // github_status: Git may execute nothing but itself (no filter, hook or
//! // helper), or run unrestricted where Landlock is unavailable.
//! let output = match ExecOnly::probe("git", &["--version"]) {
//!     Some((git, only)) => Bounded::new(git).exec_only(&only),
//!     None => Bounded::new("git"),
//! }
//! .args(["status", "--porcelain=v2"])
//! .timeout(Duration::from_secs(8))
//! .run()?;
//!
//! // artwork.py: the decoder inside bubblewrap, behind a seccomp filter.
//! let filter = BpfFilter::decoder()?.memfd()?;
//! let output = Bwrap::new("/usr/bin/bwrap")
//!     .unshare_all()
//!     .die_with_parent()
//!     .seccomp(&filter)
//!     .bounded(["/usr/bin/magick", "PNG:/input", "RGB:-"])
//!     .run()?;
//!
//! // A multithreaded decoder (ffmpeg): threads, but still no processes.
//! let filter = BpfFilter::threaded_decoder()?.memfd()?;
//! # Ok(()) }
//! ```

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use landlock::{
    AccessFs, CompatLevel, Compatible, PathBeneath, PathFd, Ruleset, RulesetAttr,
    RulesetCreatedAttr,
};
use seccompiler::{
    SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter, SeccompRule,
    TargetArch, sock_filter,
};

use crate::child::Bounded;

const SECCOMP_RET_KILL_PROCESS: u32 = 0x8000_0000;
const SECCOMP_RET_ERRNO: u32 = 0x0005_0000;
/// Syscall numbers with this bit are the x32 ABI on x86_64.
const X32_SYSCALL_BIT: u32 = 0x4000_0000;

/// Syscalls an image decoder must not make: no new processes (`clone`,
/// `clone3`, `fork`, `vfork`), namespaces (`unshare`, `setns`), `mount`
/// (only the classic call: the newer mount API, `umount2` and
/// `pivot_root` are not listed; without namespaces, which are denied, a
/// mount needs privileges the decoder doesn't have anyway), `ptrace` or
/// `bpf` (`artwork.py`'s list), and since 0.6.0 no kernel
/// attack surface a decoder never needs: io_uring (`io_uring_setup`,
/// `io_uring_enter`, `io_uring_register`), the key store (`add_key`,
/// `request_key`, `keyctl`) and `userfaultfd`. Per architecture, ascending.
pub fn decoder_denied(arch: &str) -> Option<&'static [i64]> {
    match arch {
        // clone, fork, vfork, ptrace, mount, add_key, request_key, keyctl,
        // unshare, setns, bpf, userfaultfd, io_uring_setup, io_uring_enter,
        // io_uring_register, clone3
        "x86_64" => Some(&[
            56, 57, 58, 101, 165, 248, 249, 250, 272, 308, 321, 323, 425, 426, 427, 435,
        ]),
        // mount, unshare, ptrace, add_key, request_key, keyctl, clone,
        // setns, bpf, userfaultfd, io_uring_setup, io_uring_enter,
        // io_uring_register, clone3
        "aarch64" => Some(&[
            40, 97, 117, 217, 218, 219, 220, 268, 280, 282, 425, 426, 427, 435,
        ]),
        _ => None,
    }
}

/// The syscalls [`BpfFilter::threaded_decoder`] denies outright: those of
/// [`decoder_denied`] without `clone` (allowed for threads only) and
/// `clone3` (answered with `ENOSYS`).
pub fn threaded_decoder_denied(arch: &str) -> Option<&'static [i64]> {
    match arch {
        // fork, vfork, ptrace, mount, add_key, request_key, keyctl,
        // unshare, setns, bpf, userfaultfd, io_uring_setup, io_uring_enter,
        // io_uring_register
        "x86_64" => Some(&[
            57, 58, 101, 165, 248, 249, 250, 272, 308, 321, 323, 425, 426, 427,
        ]),
        // mount, unshare, ptrace, add_key, request_key, keyctl, setns, bpf,
        // userfaultfd, io_uring_setup, io_uring_enter, io_uring_register (no
        // fork or vfork: clone)
        "aarch64" => Some(&[40, 97, 117, 217, 218, 219, 268, 280, 282, 425, 426, 427]),
        _ => None,
    }
}

/// `clone`'s syscall number, per architecture.
fn clone_nr(arch: &str) -> Option<i64> {
    match arch {
        "x86_64" => Some(56),
        "aarch64" => Some(220),
        _ => None,
    }
}

/// `clone3` on every architecture.
const CLONE3: u32 = 435;

/// The namespace flags `clone` takes (`CLONE_NEWTIME` is `clone3` and
/// `unshare` only: in `clone`'s flags its bit is part of the exit signal).
const CLONE_NEW: [u32; 7] = [
    libc::CLONE_NEWNS as u32,
    libc::CLONE_NEWCGROUP as u32,
    libc::CLONE_NEWUTS as u32,
    libc::CLONE_NEWIPC as u32,
    libc::CLONE_NEWUSER as u32,
    libc::CLONE_NEWPID as u32,
    libc::CLONE_NEWNET as u32,
];

/// A classic BPF seccomp program: kill the process on a foreign
/// architecture (and, on x86_64, for any x32 syscall), return `errno` for
/// the listed syscalls (with [`threaded_decoder`](Self::threaded_decoder)
/// also for `clone` with the wrong flags, and `ENOSYS` for `clone3`), allow
/// everything else.
#[derive(Debug, Clone)]
pub struct BpfFilter {
    program: Vec<sock_filter>,
}

fn unsupported(why: &str) -> io::Error {
    io::Error::new(io::ErrorKind::Unsupported, why.to_string())
}

impl BpfFilter {
    /// Denies `syscalls` (numbers for this architecture) with `errno`.
    pub fn deny(syscalls: &[i64], errno: u32) -> io::Result<BpfFilter> {
        BpfFilter::deny_for(std::env::consts::ARCH, syscalls, errno)
    }

    /// `artwork.py`'s `decoder_filter()`, hardened in 0.6.0 (io_uring, the
    /// key store and `userfaultfd` too): [`decoder_denied`] with `EPERM`.
    /// `Unsupported` on other architectures
    /// (`sandbox-architecture-unsupported`).
    pub fn decoder() -> io::Result<BpfFilter> {
        let arch = std::env::consts::ARCH;
        let denied =
            decoder_denied(arch).ok_or_else(|| unsupported("sandbox-architecture-unsupported"))?;
        BpfFilter::deny_for(arch, denied, libc::EPERM as u32)
    }

    /// The image decoder's filter for a decoder that runs threads (ffmpeg):
    /// [`threaded_decoder_denied`] with `EPERM`; `clone` only for a thread
    /// (`CLONE_THREAD` set, no `CLONE_NEW*` flag), otherwise `EPERM`;
    /// `clone3` with `ENOSYS` (its flags are in memory, where seccomp can't
    /// look), so glibc falls back to `clone`. No new processes or
    /// namespaces, as with [`decoder`](Self::decoder); foreign
    /// architectures and x32 are killed the same way. `Unsupported` on
    /// other architectures (`sandbox-architecture-unsupported`).
    pub fn threaded_decoder() -> io::Result<BpfFilter> {
        BpfFilter::threaded_decoder_for(std::env::consts::ARCH)
    }

    fn threaded_decoder_for(arch: &str) -> io::Result<BpfFilter> {
        let unsupported_arch = || unsupported("sandbox-architecture-unsupported");
        let denied = threaded_decoder_denied(arch).ok_or_else(unsupported_arch)?;
        let clone = clone_nr(arch).ok_or_else(unsupported_arch)?;
        let mut rules: BTreeMap<i64, Vec<SeccompRule>> =
            denied.iter().map(|&nr| (nr, Vec::new())).collect();
        // The kernel reads only the low 32 bits of clone's flags
        // (`lower_32_bits(clone_flags)`), so that is what is compared. A
        // syscall matches if any of its rules does: no CLONE_THREAD, or any
        // namespace flag.
        let flags = |mask: u32, value: u32| -> io::Result<SeccompRule> {
            let condition = SeccompCondition::new(
                0,
                SeccompCmpArgLen::Dword,
                SeccompCmpOp::MaskedEq(u64::from(mask)),
                u64::from(value),
            )
            .map_err(io::Error::other)?;
            SeccompRule::new(vec![condition]).map_err(io::Error::other)
        };
        let mut clone_rules = vec![flags(libc::CLONE_THREAD as u32, 0)?];
        for namespace in CLONE_NEW {
            clone_rules.push(flags(namespace, namespace)?);
        }
        rules.insert(clone, clone_rules);
        let mut program = BpfFilter::compile(arch, rules, libc::EPERM as u32)?;
        // clone3 → ENOSYS (seccompiler has one match action per filter):
        // after the architecture (and x32) check, before its own rules.
        let at = if arch == "x86_64" { 6 } else { 3 };
        let clone3 = [
            sock_filter {
                code: 0x20,
                jt: 0,
                jf: 0,
                k: 0,
            },
            sock_filter {
                code: 0x15,
                jt: 0,
                jf: 1,
                k: CLONE3,
            },
            sock_filter {
                code: 0x06,
                jt: 0,
                jf: 0,
                k: SECCOMP_RET_ERRNO | libc::ENOSYS as u32,
            },
        ];
        program.splice(at..at, clone3);
        Ok(BpfFilter { program })
    }

    fn deny_for(arch: &str, syscalls: &[i64], errno: u32) -> io::Result<BpfFilter> {
        let rules: BTreeMap<i64, Vec<_>> = syscalls.iter().map(|&nr| (nr, Vec::new())).collect();
        Ok(BpfFilter {
            program: BpfFilter::compile(arch, rules, errno)?,
        })
    }

    /// seccompiler's program for `rules` (matches return `errno`, the rest
    /// is allowed) with the x32 check on x86_64.
    fn compile(
        arch: &str,
        rules: BTreeMap<i64, Vec<SeccompRule>>,
        errno: u32,
    ) -> io::Result<Vec<sock_filter>> {
        let target =
            TargetArch::try_from(arch).map_err(|_| unsupported("unsupported architecture"))?;
        let filter = SeccompFilter::new(
            rules,
            SeccompAction::Allow,
            SeccompAction::Errno(errno),
            target,
        )
        .map_err(io::Error::other)?;
        let mut program: Vec<sock_filter> = filter.try_into().map_err(io::Error::other)?;
        if arch == "x86_64" {
            // seccompiler checks the architecture but not the x32 ABI, whose
            // syscall numbers would bypass the list. After its 3-instruction
            // architecture check: load the number, kill if the x32 bit is set
            // (as artwork.py's filter does). Later jumps are relative and
            // stay valid.
            let x32 = [
                sock_filter {
                    code: 0x20,
                    jt: 0,
                    jf: 0,
                    k: 0,
                },
                sock_filter {
                    code: 0x45,
                    jt: 0,
                    jf: 1,
                    k: X32_SYSCALL_BIT,
                },
                sock_filter {
                    code: 0x06,
                    jt: 0,
                    jf: 0,
                    k: SECCOMP_RET_KILL_PROCESS,
                },
            ];
            program.splice(3..3, x32);
        }
        Ok(program)
    }

    /// The program as an array of `struct sock_filter` in native byte
    /// order: what `bwrap --seccomp <fd>` reads.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.program.len() * 8);
        for insn in &self.program {
            out.extend_from_slice(&insn.code.to_ne_bytes());
            out.push(insn.jt);
            out.push(insn.jf);
            out.extend_from_slice(&insn.k.to_ne_bytes());
        }
        out
    }

    /// Number of instructions.
    pub fn len(&self) -> usize {
        self.program.len()
    }

    /// Never true (a filter has at least its architecture check).
    pub fn is_empty(&self) -> bool {
        self.program.is_empty()
    }

    /// A memfd holding [`to_bytes`](Self::to_bytes), positioned at its
    /// start and close-on-exec: give it to [`Bwrap::seccomp`], which passes
    /// it to bubblewrap (`artwork.py`'s `memfd_create` + `pass_fds`).
    pub fn memfd(&self) -> io::Result<OwnedFd> {
        let fd = rustix::fs::memfd_create("foamy-seccomp", rustix::fs::MemfdFlags::CLOEXEC)?;
        let mut file = File::from(fd);
        file.write_all(&self.to_bytes())?;
        rustix::fs::seek(&file, rustix::fs::SeekFrom::Start(0))?;
        Ok(OwnedFd::from(file))
    }
}

/// Sets `PR_SET_NO_NEW_PRIVS`; async-signal-safe.
fn no_new_privs() -> io::Result<()> {
    // SAFETY: prctl with integer arguments only.
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Installs a seccomp program on the calling thread; async-signal-safe.
fn install(program: &[sock_filter]) -> io::Result<()> {
    no_new_privs()?;
    let fprog = libc::sock_fprog {
        len: program.len() as libc::c_ushort,
        // `sock_filter` is `#[repr(C)]` with the kernel's layout.
        filter: program.as_ptr() as *mut libc::sock_filter,
    };
    // SAFETY: `fprog` points to `program`, which outlives the call; the
    // kernel copies the program.
    let rc = unsafe {
        libc::syscall(
            libc::SYS_seccomp,
            libc::SECCOMP_SET_MODE_FILTER,
            0,
            &fprog as *const libc::sock_fprog,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// A Landlock ruleset that handles only "execute": a child restricted by it
/// may `execve` (and have the kernel load as an ELF interpreter) only the
/// allowed files, whatever its configuration says, so it can't start the
/// filters, hooks or helpers it would run by path. Everything else
/// (reading, writing, networking) stays as it was. Equivalent to
/// `setpriv --landlock-access fs:execute --landlock-rule
/// path-beneath:execute:<path>…`, applied in the child just before `exec`.
///
/// It is not a barrier against code that already runs in the child:
/// Landlock checks `execve`, not `mmap`, so an allowed dynamic loader runs
/// any readable binary given as its argument (`ld-linux-x86-64.so.2
/// /bin/sh -c …`), and an allowed interpreter runs any script.
#[derive(Debug)]
pub struct ExecOnly {
    ruleset: OwnedFd,
    allowed: Vec<PathBuf>,
}

impl ExecOnly {
    /// Allows executing exactly `paths` (files, or everything beneath a
    /// directory). `Unsupported` when the kernel has no Landlock (never a
    /// silently weaker sandbox).
    pub fn new<P: AsRef<Path>>(paths: &[P]) -> io::Result<ExecOnly> {
        let landlock =
            |error: landlock::RulesetError| io::Error::new(io::ErrorKind::Unsupported, error);
        let mut ruleset = Ruleset::default()
            .set_compatibility(CompatLevel::HardRequirement)
            .handle_access(AccessFs::Execute)
            .map_err(landlock)?
            .create()
            .map_err(landlock)?;
        let mut allowed = Vec::new();
        for path in paths {
            let path = path.as_ref();
            let fd = PathFd::new(path)
                .map_err(|error| io::Error::new(io::ErrorKind::NotFound, error))?;
            ruleset = ruleset
                .add_rule(PathBeneath::new(fd, AccessFs::Execute))
                .map_err(landlock)?;
            allowed.push(path.to_path_buf());
        }
        let ruleset: Option<OwnedFd> = ruleset.into();
        let ruleset = ruleset.ok_or_else(|| unsupported("Landlock is not available"))?;
        Ok(ExecOnly { ruleset, allowed })
    }

    /// Allows `program` and its ELF interpreter (the dynamic loader), as
    /// github_status does for Git. The loader can run other binaries when
    /// invoked directly (see [`ExecOnly`]); a program that execs only by
    /// path, as Git does, can't use that.
    pub fn for_program(program: &Path) -> io::Result<ExecOnly> {
        let mut paths = vec![program.to_path_buf()];
        paths.extend(elf_interpreter(program));
        ExecOnly::new(&paths)
    }

    /// github_status's `_probe_sandbox`: finds `name` in `PATH` (resolved
    /// to its real path), restricts execution to it and its interpreter,
    /// and checks that the restriction works (`<program> <args>` exits 0)
    /// and bites (`/bin/sh -c 'exit 0'` cannot be executed directly; through
    /// the allowed loader it could, see [`ExecOnly`]). Returns the program to
    /// run and the restriction, or `None`: then run unrestricted, as the
    /// Python helper did without setpriv or Landlock. Probe once and keep
    /// the result.
    pub fn probe(name: &str, args: &[&str]) -> Option<(PathBuf, ExecOnly)> {
        let program = std::fs::canonicalize(which(name)?).ok()?;
        let only = ExecOnly::for_program(&program).ok()?;
        let limited = |command: Bounded| {
            command
                .exec_only(&only)
                .timeout(Duration::from_secs(5))
                .run()
        };
        let works =
            limited(Bounded::new(&program).args(args)).is_ok_and(|out| out.status.success());
        let blocked = limited(Bounded::new("/bin/sh").args(["-c", "exit 0"]))
            .map_or(true, |out| !out.status.success());
        (works && blocked).then_some((program, only))
    }

    /// The files and directories that may be executed.
    pub fn allowed(&self) -> &[PathBuf] {
        &self.allowed
    }

    /// Restricts `command`'s child (`pre_exec`). For [`Bounded`] use
    /// [`Bounded::exec_only`].
    pub fn apply_to(&self, command: &mut Command) -> io::Result<()> {
        let hook = self.hook()?;
        // SAFETY: the hook only makes system calls (prctl,
        // landlock_restrict_self) on an fd it owns; no allocation or locks.
        unsafe {
            command.pre_exec(hook);
        }
        Ok(())
    }

    fn hook(&self) -> io::Result<impl Fn() -> io::Result<()> + Send + Sync + 'static> {
        let ruleset = self.ruleset.try_clone()?;
        Ok(move || {
            no_new_privs()?;
            // SAFETY: landlock_restrict_self(2) with a ruleset fd that is
            // open for the closure's lifetime and no flags.
            let rc =
                unsafe { libc::syscall(libc::SYS_landlock_restrict_self, ruleset.as_raw_fd(), 0) };
            if rc != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        })
    }
}

impl Bounded {
    /// Runs the child under `only` (see [`ExecOnly`]).
    pub fn exec_only(self, only: &ExecOnly) -> Bounded {
        match only.hook() {
            Ok(hook) => self.pre_exec_hook(Box::new(hook)),
            // Could not duplicate the ruleset fd: fail the spawn, never run
            // the child unrestricted.
            Err(error) => {
                let code = error.raw_os_error().unwrap_or(libc::EMFILE);
                self.pre_exec_hook(Box::new(move || Err(io::Error::from_raw_os_error(code))))
            }
        }
    }

    /// Installs `filter` in the child just before `exec` (after
    /// `PR_SET_NO_NEW_PRIVS`). With bubblewrap use [`Bwrap::seccomp`]
    /// instead, which installs it after bubblewrap's own setup.
    pub fn seccomp(self, filter: &BpfFilter) -> Bounded {
        let program = filter.program.clone();
        self.pre_exec_hook(Box::new(move || install(&program)))
    }
}

/// The ELF interpreter (`PT_INTERP`, the dynamic loader) of a 64-bit
/// little-endian ELF, from its first 64 KiB; `None` for a static binary,
/// another format or an unreadable file. github_status's `elf_interpreter`.
pub fn elf_interpreter(path: &Path) -> Option<PathBuf> {
    let mut data = Vec::new();
    File::open(path)
        .ok()?
        .take(1 << 16)
        .read_to_end(&mut data)
        .ok()?;
    if data.len() < 0x40 || &data[..4] != b"\x7fELF" || data[4] != 2 || data[5] != 1 {
        return None;
    }
    let u16_at = |at: usize| Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?));
    let u32_at = |at: usize| Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?));
    let u64_at = |at: usize| Some(u64::from_le_bytes(data.get(at..at + 8)?.try_into().ok()?));
    let phoff = usize::try_from(u64_at(0x20)?).ok()?;
    let (size, count) = (u16_at(0x36)? as usize, u16_at(0x38)? as usize);
    for index in 0..count {
        let header = phoff.checked_add(index.checked_mul(size)?)?;
        if u32_at(header)? == 3 {
            let offset = usize::try_from(u64_at(header + 8)?).ok()?;
            let length = usize::try_from(u64_at(header + 32)?).ok()?;
            let end = offset.checked_add(length)?.min(data.len());
            let raw = data.get(offset.min(end)..end)?;
            let end = raw.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
            return Some(PathBuf::from(OsStr::from_bytes(&raw[..end])));
        }
    }
    None
}

/// `shutil.which`: the first executable regular file called `name` in
/// `PATH` (default `/bin:/usr/bin`), or `name` itself if it contains a `/`.
pub fn which(name: &str) -> Option<PathBuf> {
    let executable = |path: &Path| {
        std::fs::metadata(path).is_ok_and(|meta| meta.is_file())
            && rustix::fs::access(path, rustix::fs::Access::EXEC_OK).is_ok()
    };
    if name.contains('/') {
        return executable(Path::new(name)).then(|| PathBuf::from(name));
    }
    let path = std::env::var_os("PATH").unwrap_or_else(|| OsString::from("/bin:/usr/bin"));
    std::env::split_paths(&path)
        .map(|dir| {
            if dir.as_os_str().is_empty() {
                PathBuf::from(".")
            } else {
                dir
            }
        })
        .map(|dir| dir.join(name))
        .find(|candidate| executable(candidate))
}

/// A bubblewrap command line, built option by option in the order given
/// (bubblewrap applies mounts in order). File descriptors handed to it
/// (`--ro-bind-fd`, `--bind-fd`, `--seccomp`) are duplicated: bubblewrap
/// inherits them under the numbers its options name when run through
/// [`bounded`](Self::bounded), even if the caller closed them by then
/// (`.seccomp(BpfFilter::decoder()?.memfd()?)` is fine). A duplicate that
/// can't be made fails the run.
#[derive(Debug, Clone)]
pub struct Bwrap {
    program: PathBuf,
    args: Vec<OsString>,
    /// Number, duplicate, rewind before exec (`--seccomp`).
    fds: Vec<(RawFd, Arc<OwnedFd>, bool)>,
    /// `errno` of a duplicate that could not be made.
    broken: Option<i32>,
}

impl Bwrap {
    /// Bubblewrap at `program` (foamy-lock: `/usr/bin/bwrap`), no options.
    pub fn new(program: impl Into<PathBuf>) -> Bwrap {
        Bwrap {
            program: program.into(),
            args: Vec::new(),
            fds: Vec::new(),
            broken: None,
        }
    }

    /// `bwrap` from `PATH` (foamy-github), or `None`.
    pub fn find() -> Option<Bwrap> {
        which("bwrap").map(Bwrap::new)
    }

    /// github_status's namespace: the whole filesystem read-only, a fresh
    /// minimal `/dev`, its own PID (with `/proc`), IPC and UTS namespaces,
    /// the network shared, dying with the helper. Add binds after it.
    pub fn readonly_host(self) -> Bwrap {
        self.ro_bind("/", "/")
            .dev("/dev")
            .unshare_pid()
            .proc("/proc")
            .unshare_ipc()
            .unshare_uts()
            .die_with_parent()
    }

    fn push<I, S>(mut self, args: I) -> Bwrap
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.args
            .extend(args.into_iter().map(|a| a.as_ref().to_os_string()));
        self
    }

    fn with_fd(
        mut self,
        option: &str,
        fd: BorrowedFd<'_>,
        rest: Option<&OsStr>,
        rewind: bool,
    ) -> Bwrap {
        // The option names the retained duplicate's number, not the
        // caller's: a temporary fd's number is free again once it is
        // dropped, so two temporaries can share one, while each duplicate
        // keeps its own number as long as the builder holds it.
        let number = match fd.try_clone_to_owned() {
            Ok(owned) => {
                let number = owned.as_raw_fd();
                self.fds.push((number, Arc::new(owned), rewind));
                number
            }
            Err(error) => {
                let code = error.raw_os_error().unwrap_or(libc::EMFILE);
                self.broken.get_or_insert(code);
                fd.as_raw_fd()
            }
        }
        .to_string();
        self.args.push(option.into());
        self.args.push(number.into());
        if let Some(rest) = rest {
            self.args.push(rest.to_os_string());
        }
        self
    }

    /// Any option bubblewrap knows, verbatim.
    pub fn arg(self, arg: impl AsRef<OsStr>) -> Bwrap {
        self.push([arg])
    }

    /// `--ro-bind <source> <dest>`.
    pub fn ro_bind(self, source: impl AsRef<OsStr>, dest: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--ro-bind"), source.as_ref(), dest.as_ref()])
    }

    /// `--bind <source> <dest>`.
    pub fn bind(self, source: impl AsRef<OsStr>, dest: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--bind"), source.as_ref(), dest.as_ref()])
    }

    /// `--ro-bind-fd <fd> <dest>`: an open directory, bound read-only.
    pub fn ro_bind_fd(self, fd: impl AsFd, dest: impl AsRef<OsStr>) -> Bwrap {
        self.with_fd("--ro-bind-fd", fd.as_fd(), Some(dest.as_ref()), false)
    }

    /// `--bind-fd <fd> <dest>`: an open directory, bound writable.
    pub fn bind_fd(self, fd: impl AsFd, dest: impl AsRef<OsStr>) -> Bwrap {
        self.with_fd("--bind-fd", fd.as_fd(), Some(dest.as_ref()), false)
    }

    /// `--dev <dest>`: a fresh minimal `/dev`.
    pub fn dev(self, dest: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--dev"), dest.as_ref()])
    }

    /// `--proc <dest>`.
    pub fn proc(self, dest: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--proc"), dest.as_ref()])
    }

    /// `--dir <dest>`.
    pub fn dir(self, dest: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--dir"), dest.as_ref()])
    }

    /// `--tmpfs <dest>`.
    pub fn tmpfs(self, dest: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--tmpfs"), dest.as_ref()])
    }

    /// `--symlink <target> <link>`.
    pub fn symlink(self, target: impl AsRef<OsStr>, link: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--symlink"), target.as_ref(), link.as_ref()])
    }

    /// `--remount-ro <dest>`.
    pub fn remount_ro(self, dest: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--remount-ro"), dest.as_ref()])
    }

    /// `--chdir <dir>`.
    pub fn chdir(self, dir: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--chdir"), dir.as_ref()])
    }

    /// `--clearenv`.
    pub fn clearenv(self) -> Bwrap {
        self.push(["--clearenv"])
    }

    /// `--setenv <name> <value>`.
    pub fn setenv(self, name: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--setenv"), name.as_ref(), value.as_ref()])
    }

    /// `--unsetenv <name>`.
    pub fn unsetenv(self, name: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--unsetenv"), name.as_ref()])
    }

    /// `--unshare-all` (every namespace, the network included).
    pub fn unshare_all(self) -> Bwrap {
        self.push(["--unshare-all"])
    }

    /// `--unshare-pid`.
    pub fn unshare_pid(self) -> Bwrap {
        self.push(["--unshare-pid"])
    }

    /// `--unshare-ipc`.
    pub fn unshare_ipc(self) -> Bwrap {
        self.push(["--unshare-ipc"])
    }

    /// `--unshare-uts`.
    pub fn unshare_uts(self) -> Bwrap {
        self.push(["--unshare-uts"])
    }

    /// `--unshare-net`.
    pub fn unshare_net(self) -> Bwrap {
        self.push(["--unshare-net"])
    }

    /// `--die-with-parent`.
    pub fn die_with_parent(self) -> Bwrap {
        self.push(["--die-with-parent"])
    }

    /// `--new-session`.
    pub fn new_session(self) -> Bwrap {
        self.push(["--new-session"])
    }

    /// `--cap-drop <cap>` (`"ALL"`).
    pub fn cap_drop(self, cap: impl AsRef<OsStr>) -> Bwrap {
        self.push([OsStr::new("--cap-drop"), cap.as_ref()])
    }

    /// `--seccomp <fd>`: bubblewrap installs the filter in `fd` (see
    /// [`BpfFilter::memfd`]) just before executing the command. Bubblewrap
    /// reads it from the fd's offset, which every copy shares, so each run
    /// seeks it back to the start before exec: the same filter and builder
    /// serve any number of runs ([`works`](Self::works) and then the real
    /// one), one after the other. Runs that overlap in time (a
    /// [`crate::child::Pipeline`]'s two stages) need a memfd each.
    pub fn seccomp(self, fd: impl AsFd) -> Bwrap {
        self.with_fd("--seccomp", fd.as_fd(), None, true)
    }

    /// `--`: the end of the options (github_status's prefix ends with it).
    pub fn end_of_options(self) -> Bwrap {
        self.push(["--"])
    }

    /// The options so far (without the bubblewrap program).
    pub fn args(&self) -> &[OsString] {
        &self.args
    }

    /// The full argv: bubblewrap, the options, then `command`.
    pub fn argv<I, S>(&self, command: I) -> Vec<OsString>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let mut argv = vec![self.program.clone().into_os_string()];
        argv.extend(self.args.iter().cloned());
        argv.extend(command.into_iter().map(|a| a.as_ref().to_os_string()));
        argv
    }

    /// A [`Bounded`] running [`argv`](Self::argv), inheriting the fds the
    /// options name. Add the bounds (`timeout`, `max_output`, `env_clear`,
    /// `rlimit`, …) to it.
    pub fn bounded<I, S>(&self, command: I) -> Bounded
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let mut bounded = Bounded::new(&self.program).args(&self.args).args(command);
        for (number, fd, rewind) in &self.fds {
            bounded = bounded.inherit_shared(*number, Arc::clone(fd), *rewind);
        }
        if let Some(code) = self.broken {
            bounded = bounded.fail_spawn(io::Error::from_raw_os_error(code));
        }
        bounded
    }

    /// github_status's probe: whether `<bwrap> <options> -- true` exits 0
    /// within 5 s (bubblewrap may be installed but unusable, e.g. without
    /// unprivileged user namespaces).
    pub fn works(&self) -> bool {
        self.bounded(["--", "true"])
            .timeout(Duration::from_secs(5))
            .run()
            .is_ok_and(|out| out.success())
    }
}

#[cfg(test)]
mod tests;
