// foamy-kit 0.9.0 d0471dc6a0e3585b6fa76a6adfc16665b7b826925eeda5b72c71a4bf6e0a831e — do not edit; change foamy-kit and run sync
use super::*;
use std::time::Duration;

const ALLOW: u32 = 0x7fff_0000;
const EPERM: u32 = 0x0005_0001;
const KILL: u32 = SECCOMP_RET_KILL_PROCESS;
const AUDIT_X86_64: u32 = 0xc000_003e;
const AUDIT_AARCH64: u32 = 0xc000_00b7;

/// io_uring_setup, io_uring_enter and io_uring_register: the same numbers on
/// both architectures.
const IO_URING: [u32; 3] = [425, 426, 427];

/// The syscalls 0.6.0 added to both decoder profiles, by name: io_uring,
/// the key store and userfaultfd (the numbers are from the kernel's
/// `unistd_64.h` and `asm-generic/unistd.h`, written out independently of
/// the lists in `sandbox.rs`).
fn hardening(arch: &str) -> [(&'static str, u32); 7] {
    let (add_key, request_key, keyctl, userfaultfd) = match arch {
        "x86_64" => (248, 249, 250, 323),
        _ => (217, 218, 219, 282),
    };
    [
        ("io_uring_setup", IO_URING[0]),
        ("io_uring_enter", IO_URING[1]),
        ("io_uring_register", IO_URING[2]),
        ("add_key", add_key),
        ("request_key", request_key),
        ("keyctl", keyctl),
        ("userfaultfd", userfaultfd),
    ]
}

/// artwork.py's `decoder_filter()`, instruction for instruction, with 0.6.0's
/// [`hardening`] denied the same way.
fn python_reference(arch: &str) -> Vec<sock_filter> {
    let (audit, mut denied): (u32, Vec<u32>) = match arch {
        "x86_64" => (AUDIT_X86_64, vec![56, 57, 58, 101, 165, 272, 308, 321, 435]),
        _ => (AUDIT_AARCH64, vec![40, 97, 117, 220, 268, 280, 435]),
    };
    denied.extend(hardening(arch).map(|(_, nr)| nr));
    let insn = |code, jt, jf, k| sock_filter { code, jt, jf, k };
    let mut program = vec![
        insn(0x20, 0, 0, 4),
        insn(0x15, 1, 0, audit),
        insn(0x06, 0, 0, KILL),
        insn(0x20, 0, 0, 0),
    ];
    if arch == "x86_64" {
        program.extend([insn(0x45, 0, 1, X32_SYSCALL_BIT), insn(0x06, 0, 0, KILL)]);
    }
    for nr in denied {
        program.extend([insn(0x15, 0, 1, nr), insn(0x06, 0, 0, EPERM)]);
    }
    program.push(insn(0x06, 0, 0, ALLOW));
    program
}

/// A classic BPF interpreter for what seccomp filters use here: the result
/// for syscall `nr` on architecture `audit`.
fn evaluate(program: &[sock_filter], audit: u32, nr: u32) -> u32 {
    evaluate_with(program, audit, nr, 0)
}

/// [`evaluate`] with `arg0` as the first argument.
fn evaluate_with(program: &[sock_filter], audit: u32, nr: u32, arg0: u64) -> u32 {
    let (mut pc, mut a) = (0usize, 0u32);
    for _ in 0..10_000 {
        let insn = &program[pc];
        pc += 1;
        match insn.code {
            0x20 => {
                a = match insn.k {
                    0 => nr,
                    4 => audit,
                    // seccomp_data.args[0], low and high half (little endian).
                    16 => arg0 as u32,
                    20 => (arg0 >> 32) as u32,
                    other => panic!("load of seccomp_data offset {other}"),
                }
            }
            0x05 => pc += insn.k as usize,
            0x15 | 0x25 | 0x35 | 0x45 => {
                let taken = match insn.code {
                    0x15 => a == insn.k,
                    0x25 => a > insn.k,
                    0x35 => a >= insn.k,
                    _ => a & insn.k != 0,
                };
                pc += if taken { insn.jt } else { insn.jf } as usize;
            }
            0x54 => a &= insn.k,
            0x06 => return insn.k,
            other => panic!("unexpected BPF instruction {other:#x}"),
        }
    }
    panic!("filter did not return")
}

#[test]
fn decoder_filter_matches_artwork_py_for_every_syscall() {
    for (arch, audit, other) in [
        ("x86_64", AUDIT_X86_64, AUDIT_AARCH64),
        ("aarch64", AUDIT_AARCH64, AUDIT_X86_64),
    ] {
        let ours = BpfFilter::deny_for(arch, decoder_denied(arch).unwrap(), 1)
            .unwrap()
            .program;
        let reference = python_reference(arch);
        let numbers = (0..1024u32)
            .chain((0..1024).map(|n| n | X32_SYSCALL_BIT))
            .chain([u32::MAX]);
        for nr in numbers {
            for machine in [audit, other, 0x4000_0003] {
                assert_eq!(
                    evaluate(&ours, machine, nr),
                    evaluate(&reference, machine, nr),
                    "{arch}: syscall {nr:#x} on audit arch {machine:#x}"
                );
            }
        }
        assert_eq!(
            evaluate(&ours, audit, decoder_denied(arch).unwrap()[0] as u32),
            EPERM
        );
        assert_eq!(evaluate(&ours, audit, 0), ALLOW);
        assert_eq!(evaluate(&ours, other, 0), KILL);
    }
    let filter = BpfFilter::decoder().unwrap();
    assert_eq!(filter.to_bytes().len(), filter.len() * 8);
    assert!(!filter.is_empty());
    assert!(BpfFilter::deny_for("powerpc64", &[1], 1).is_err());
}

#[test]
fn memfd_holds_the_program_for_bubblewrap() {
    let filter = BpfFilter::decoder().unwrap();
    let fd = filter.memfd().unwrap();
    let mut bytes = Vec::new();
    File::from(fd.try_clone().unwrap())
        .read_to_end(&mut bytes)
        .unwrap();
    assert_eq!(bytes, filter.to_bytes());
    // The duplicate shares the offset; the memfd itself was at its start.
    let script = format!("wc -c < /proc/self/fd/{}", fd.as_raw_fd());
    let output = Bounded::new("/bin/sh")
        .args(["-c", &script])
        .inherit_fd(&fd)
        .run()
        .unwrap();
    assert_eq!(
        output.stdout_lossy().trim(),
        filter.to_bytes().len().to_string()
    );
}

/// A stand-in for bubblewrap that copies the fd its `--seccomp` option
/// names (`$2`) to standard output, as bubblewrap reads it.
fn fake_bwrap(dir: &Path) -> Bwrap {
    use std::os::unix::fs::PermissionsExt;
    let program = dir.join("bwrap");
    std::fs::write(&program, "#!/bin/sh\nexec cat <&\"$2\"\n").unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    Bwrap::new(program)
}

#[test]
fn bwrap_keeps_its_own_copy_of_the_fds_it_names() {
    // The memfd is a temporary: closed when `seccomp` returns. Before,
    // only its number was kept, and the next fd opened (here a file) took
    // it and went to bubblewrap instead.
    let dir = crate::fs::tests::TempDir::new("bwrap-fds");
    let other = dir.0.join("other");
    std::fs::write(&other, b"some other file").unwrap();
    let filter = BpfFilter::decoder().unwrap();
    let sandbox = fake_bwrap(&dir.0).seccomp(filter.memfd().unwrap());
    let _reused = File::open(&other).unwrap();
    let output = sandbox.bounded(["--", "true"]).run().unwrap();
    assert!(output.success(), "{output:?}");
    assert_eq!(output.stdout, filter.to_bytes());
}

#[test]
fn a_seccomp_memfd_serves_more_than_one_run() {
    // bubblewrap reads the filter from the shared offset: after one run it
    // was at the end, and the next run (`works()` and then the real one,
    // say) read nothing ("Invalid seccomp data").
    let dir = crate::fs::tests::TempDir::new("bwrap-rewind");
    let filter = BpfFilter::threaded_decoder().unwrap();
    let memfd = filter.memfd().unwrap();
    let sandbox = fake_bwrap(&dir.0).seccomp(&memfd);
    for run in 0..2 {
        let output = sandbox.bounded(["--", "true"]).run().unwrap();
        assert!(output.success(), "{output:?}");
        assert_eq!(output.stdout, filter.to_bytes(), "run {run}");
    }
    // Another builder with the same memfd too.
    let output = fake_bwrap(&dir.0)
        .seccomp(&memfd)
        .bounded(["--", "true"])
        .run()
        .unwrap();
    assert_eq!(output.stdout, filter.to_bytes());
}

#[test]
fn seccomp_in_the_child_denies_processes_and_namespaces() {
    let filter = BpfFilter::decoder().unwrap();
    let run = |script: &str| {
        Bounded::new("/bin/sh")
            .args(["-c", script])
            .env("LC_ALL", "C")
            .seccomp(&filter)
            .timeout(Duration::from_secs(5))
            .run()
            .unwrap()
    };
    assert_eq!(
        run("exit 7").status.code(),
        Some(7),
        "the filtered child runs"
    );
    // Not the last command, so the shell has to fork for it.
    let spawn = run("/usr/bin/true && echo spawned; exit 0");
    assert!(spawn.stdout.is_empty(), "no child processes: {spawn:?}");
    if Path::new("/usr/bin/unshare").exists() {
        let unshare = run("exec /usr/bin/unshare --user /usr/bin/true");
        assert!(!unshare.status.success(), "no namespaces: {unshare:?}");
        assert!(
            String::from_utf8_lossy(&unshare.stderr).contains("not permitted"),
            "{unshare:?}"
        );
    }
}

fn shell() -> PathBuf {
    std::fs::canonicalize("/bin/sh").unwrap()
}

#[test]
fn exec_only_allows_the_program_and_nothing_else() {
    let only = match ExecOnly::for_program(&shell()) {
        Ok(only) => only,
        Err(error) if error.kind() == io::ErrorKind::Unsupported => {
            eprintln!("SKIP Landlock tests: {error}");
            return;
        }
        Err(error) => panic!("{error}"),
    };
    assert_eq!(only.allowed()[0], shell());
    let run = |script: &str| {
        Bounded::new(shell())
            .args(["-c", script])
            .exec_only(&only)
            .run()
            .unwrap()
    };
    assert_eq!(run("exit 3").status.code(), Some(3));
    let other = run("exec /usr/bin/true");
    assert_eq!(
        other.status.code(),
        Some(126),
        "executing anything else is denied: {other:?}"
    );
    // The same through std::process::Command.
    let mut command = Command::new(shell());
    command.args(["-c", "exec /usr/bin/true"]);
    only.apply_to(&mut command).unwrap();
    assert_eq!(command.status().unwrap().code(), Some(126));
    // A program that isn't allowed can't even start.
    assert!(
        Bounded::new("/usr/bin/true")
            .exec_only(&only)
            .run()
            .is_err()
    );
    assert!(ExecOnly::new(&[Path::new("/nonexistent/foamy")]).is_err());
}

#[test]
fn probe_resolves_the_real_program_like_github_status() {
    if which("git").is_none() {
        eprintln!("SKIP probe test: no git");
        return;
    }
    match ExecOnly::probe("git", &["--version"]) {
        Some((git, only)) => {
            assert!(git.is_absolute() && git == std::fs::canonicalize(&git).unwrap());
            assert_eq!(only.allowed()[0], git);
            let version = Bounded::new(&git)
                .arg("--version")
                .exec_only(&only)
                .run()
                .unwrap();
            assert!(version.success() && version.stdout_lossy().starts_with("git version"));
        }
        None => eprintln!("SKIP probe test: Landlock unavailable"),
    }
    assert!(ExecOnly::probe("foamy-no-such-program", &[]).is_none());
}

#[test]
fn elf_interpreters_and_path_lookup() {
    let interpreter = elf_interpreter(&shell());
    if let Some(interpreter) = &interpreter {
        assert!(
            interpreter.is_absolute() && interpreter.exists(),
            "{interpreter:?}"
        );
    }
    let dir = crate::fs::tests::TempDir::new("elf");
    let text = dir.0.join("text");
    std::fs::write(&text, b"#!/bin/sh\nexit 0\n").unwrap();
    assert_eq!(elf_interpreter(&text), None);
    let mut truncated = b"\x7fELF\x02\x01".to_vec();
    truncated.resize(0x40, 0);
    truncated[0x38] = 9; // nine program headers that aren't there
    std::fs::write(&text, &truncated).unwrap();
    assert_eq!(elf_interpreter(&text), None);
    assert_eq!(elf_interpreter(Path::new("/nonexistent/foamy")), None);
    assert!(which("sh").is_some_and(|sh| sh.is_absolute()));
    assert_eq!(which("/bin/sh"), Some(PathBuf::from("/bin/sh")));
    assert_eq!(which("foamy-no-such-program"), None);
    assert_eq!(which(text.to_str().unwrap()), None, "not executable");
}

#[test]
fn bwrap_argv_covers_artwork_and_github_status() {
    let filter = BpfFilter::decoder().unwrap().memfd().unwrap();
    let fd = filter.as_raw_fd().to_string();
    let decoder = Bwrap::new("/usr/bin/bwrap")
        .unshare_all()
        .die_with_parent()
        .new_session()
        .cap_drop("ALL")
        .ro_bind("/usr", "/usr")
        .symlink("usr/lib", "/lib")
        .symlink("usr/lib", "/lib64")
        .symlink("usr/bin", "/bin")
        .proc("/proc")
        .dev("/dev")
        .dir("/etc")
        .dir("/etc/ImageMagick-7")
        .ro_bind("/job/policy.xml", "/etc/ImageMagick-7/policy.xml")
        .ro_bind("/job/input", "/input")
        .chdir("/")
        .clearenv()
        .setenv("PATH", "/usr/bin")
        .setenv("HOME", "/nonexistent")
        .setenv("MAGICK_CONFIGURE_PATH", "/etc/ImageMagick-7")
        .setenv("OMP_NUM_THREADS", "1")
        .remount_ro("/")
        .seccomp(&filter);
    let argv = decoder.argv(["/usr/bin/magick", "PNG:/input", "RGB:-"]);
    let expected: Vec<&str> = vec![
        "/usr/bin/bwrap",
        "--unshare-all",
        "--die-with-parent",
        "--new-session",
        "--cap-drop",
        "ALL",
        "--ro-bind",
        "/usr",
        "/usr",
        "--symlink",
        "usr/lib",
        "/lib",
        "--symlink",
        "usr/lib",
        "/lib64",
        "--symlink",
        "usr/bin",
        "/bin",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--dir",
        "/etc",
        "--dir",
        "/etc/ImageMagick-7",
        "--ro-bind",
        "/job/policy.xml",
        "/etc/ImageMagick-7/policy.xml",
        "--ro-bind",
        "/job/input",
        "/input",
        "--chdir",
        "/",
        "--clearenv",
        "--setenv",
        "PATH",
        "/usr/bin",
        "--setenv",
        "HOME",
        "/nonexistent",
        "--setenv",
        "MAGICK_CONFIGURE_PATH",
        "/etc/ImageMagick-7",
        "--setenv",
        "OMP_NUM_THREADS",
        "1",
        "--remount-ro",
        "/",
        "--seccomp",
        &fd,
        "/usr/bin/magick",
        "PNG:/input",
        "RGB:-",
    ];
    assert_eq!(
        argv,
        expected.iter().map(OsString::from).collect::<Vec<_>>()
    );

    let worktree = File::open("/").unwrap();
    let common = File::open("/tmp").unwrap();
    let pin = Bwrap::new("/usr/bin/bwrap")
        .readonly_host()
        .ro_bind("/run/foamy/ssh_config.d-x", "/etc/ssh/ssh_config.d")
        .ro_bind_fd(&worktree, "/repo")
        .bind_fd(&common, "/repo/.git")
        .end_of_options();
    let (w, c) = (
        worktree.as_raw_fd().to_string(),
        common.as_raw_fd().to_string(),
    );
    let expected: Vec<&str> = vec![
        "/usr/bin/bwrap",
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--unshare-pid",
        "--proc",
        "/proc",
        "--unshare-ipc",
        "--unshare-uts",
        "--die-with-parent",
        "--ro-bind",
        "/run/foamy/ssh_config.d-x",
        "/etc/ssh/ssh_config.d",
        "--ro-bind-fd",
        &w,
        "/repo",
        "--bind-fd",
        &c,
        "/repo/.git",
        "--",
        "git",
        "status",
    ];
    assert_eq!(
        pin.argv(["git", "status"]),
        expected.iter().map(OsString::from).collect::<Vec<_>>()
    );
    assert_eq!(pin.args().len(), expected.len() - 3);
}

#[test]
fn bwrap_runs_with_the_seccomp_filter_and_inherited_fds() {
    let Some(bwrap) = Bwrap::find() else {
        eprintln!("SKIP bwrap test: bubblewrap not installed");
        return;
    };
    if !bwrap.clone().readonly_host().works() {
        eprintln!("SKIP bwrap test: bubblewrap can't create namespaces here");
        return;
    }
    let filter = BpfFilter::decoder().unwrap().memfd().unwrap();
    let sandbox = bwrap
        .unshare_all()
        .die_with_parent()
        .new_session()
        .cap_drop("ALL")
        .ro_bind("/usr", "/usr")
        .symlink("usr/lib", "/lib")
        .symlink("usr/lib", "/lib64")
        .symlink("usr/bin", "/bin")
        .proc("/proc")
        .dev("/dev")
        .remount_ro("/")
        .seccomp(&filter);
    let run = |script: &str| {
        sandbox
            .bounded(["/usr/bin/sh", "-c", script])
            .env_clear()
            .env("PATH", "/usr/bin")
            .timeout(Duration::from_secs(10))
            .run()
            .unwrap()
    };
    let ok = run("exec /usr/bin/true");
    assert!(ok.success(), "{ok:?}");
    // The same filter memfd again: bubblewrap must read all of it (it
    // used to find the offset at the end and refuse to start), and the
    // shell then fails to fork under it.
    let spawn = run("/usr/bin/true && echo spawned; exit 0");
    assert!(
        String::from_utf8_lossy(&spawn.stderr).contains("fork: Operation not permitted"),
        "{spawn:?}"
    );
    assert!(
        spawn.stdout.is_empty(),
        "the decoder can't start processes: {spawn:?}"
    );
}

#[test]
fn decoder_filter_bytes_are_pinned() {
    // Stronger than the behaviour check above: the exact program (sha256 of
    // `to_bytes`, little endian). 0.6.0 changed it on purpose, adding
    // io_uring, the key store and userfaultfd to the list; any other change
    // to the program fails here. The 0.5.2 list still compiles to 0.5.2's
    // bytes, so the list is the only thing that changed.
    let old: [(&str, &[i64], usize, &str); 2] = [
        (
            "x86_64",
            &[56, 57, 58, 101, 165, 272, 308, 321, 435],
            53,
            "51ff45ad40eae4ee29d21e5e4222def2b1afd52b7449b45a7ea1dc5ada05eb42",
        ),
        (
            "aarch64",
            &[40, 97, 117, 220, 268, 280, 435],
            40,
            "fa16f62d166db44e9253ac0d0df1b5145499aad79667e55f7237fe73e21dfd75",
        ),
    ];
    for (arch, list, len, sha) in old {
        let ours = BpfFilter::deny_for(arch, list, libc::EPERM as u32).unwrap();
        assert_eq!(ours.len(), len, "0.5.2 {arch}");
        assert_eq!(
            crate::hash::sha256_hex(&ours.to_bytes()),
            sha,
            "0.5.2 {arch}"
        );
    }
    for (arch, len, sha) in [
        (
            "x86_64",
            88,
            "afd31ef87c26c1c5dc92221566855b582e84cb3c92bad6bafc8d95f61336d3bc",
        ),
        (
            "aarch64",
            75,
            "93ea834601264952e9a11761b44b4fec91324592720cd7f8e497c40d6a3c7446",
        ),
    ] {
        let ours =
            BpfFilter::deny_for(arch, decoder_denied(arch).unwrap(), libc::EPERM as u32).unwrap();
        assert_eq!(ours.len(), len, "{arch}");
        assert_eq!(crate::hash::sha256_hex(&ours.to_bytes()), sha, "{arch}");
    }
}

#[test]
fn decoder_profiles_deny_io_uring_keys_and_userfaultfd() {
    for (arch, audit) in [("x86_64", AUDIT_X86_64), ("aarch64", AUDIT_AARCH64)] {
        let decoder = BpfFilter::deny_for(arch, decoder_denied(arch).unwrap(), libc::EPERM as u32)
            .unwrap()
            .program;
        let threaded = BpfFilter::threaded_decoder_for(arch).unwrap().program;
        for (name, nr) in hardening(arch) {
            for arg0 in [0, 1, u64::MAX] {
                assert_eq!(
                    evaluate_with(&decoder, audit, nr, arg0),
                    EPERM,
                    "decoder {arch} {name}"
                );
                assert_eq!(
                    evaluate_with(&threaded, audit, nr, arg0),
                    EPERM,
                    "threaded {arch} {name}"
                );
            }
            assert!(decoder_denied(arch).unwrap().contains(&i64::from(nr)));
            assert!(
                threaded_decoder_denied(arch)
                    .unwrap()
                    .contains(&i64::from(nr))
            );
        }
        // The lists grew by exactly these (0.5.2's lists plus seven).
        let (decoder_len, threaded_len) = if arch == "x86_64" { (16, 14) } else { (14, 12) };
        assert_eq!(decoder_denied(arch).unwrap().len(), decoder_len, "{arch}");
        assert_eq!(
            threaded_decoder_denied(arch).unwrap().len(),
            threaded_len,
            "{arch}"
        );
        assert_eq!(evaluate(&decoder, audit, 0), ALLOW, "{arch} read/io_setup");
    }
}

const ENOSYS: u32 = 0x0005_0026;
/// glibc's pthread_create flags (CLONE_VM | FS | FILES | SIGHAND | THREAD |
/// SYSVSEM | SETTLS | PARENT_SETTID | CHILD_CLEARTID).
const PTHREAD_FLAGS: u64 = 0x003d_0f00;

/// What the threaded decoder profile must answer, written independently of
/// the filter: the reference for every syscall and flag combination.
fn threaded_reference(arch: &str, audit: u32, nr: u32, flags: u64) -> u32 {
    let (native, clone, denied): (u32, u32, &[u32]) = match arch {
        "x86_64" => (AUDIT_X86_64, 56, &[57, 58, 101, 165, 272, 308, 321]),
        _ => (AUDIT_AARCH64, 220, &[40, 97, 117, 268, 280]),
    };
    if audit != native || (arch == "x86_64" && nr & X32_SYSCALL_BIT != 0) {
        return KILL;
    }
    if nr == 435 {
        return ENOSYS;
    }
    if denied.contains(&nr) || hardening(arch).iter().any(|&(_, h)| h == nr) {
        return EPERM;
    }
    // CLONE_NEWNS, NEWCGROUP, NEWUTS, NEWIPC, NEWUSER, NEWPID, NEWNET; only
    // the low 32 bits count, as in the kernel.
    let low = flags as u32;
    if nr == clone && (low & 0x0001_0000 == 0 || low & 0x7e02_0000 != 0) {
        return EPERM;
    }
    ALLOW
}

#[test]
fn threaded_decoder_filter_allows_threads_only() {
    let mut samples = vec![
        0,
        u64::from(libc::SIGCHLD as u32),
        0x0001_0000, // CLONE_THREAD alone
        PTHREAD_FLAGS,
        PTHREAD_FLAGS | 0xffff_ffff_0000_0000, // high bits: ignored by the kernel
        0xffff_ffff_0001_0000,
        0xffff_ffff_0000_0000,
        u64::MAX,
    ];
    for bit in 0..64 {
        samples.push(1 << bit);
        samples.push(PTHREAD_FLAGS | 1 << bit);
    }
    for namespace in CLONE_NEW {
        samples.push(PTHREAD_FLAGS | u64::from(namespace));
        samples.push(u64::from(namespace));
    }
    for (arch, audit, other) in [
        ("x86_64", AUDIT_X86_64, AUDIT_AARCH64),
        ("aarch64", AUDIT_AARCH64, AUDIT_X86_64),
    ] {
        let program = BpfFilter::threaded_decoder_for(arch).unwrap().program;
        let numbers = (0..1024u32)
            .chain((0..1024).map(|n| n | X32_SYSCALL_BIT))
            .chain([u32::MAX]);
        for nr in numbers {
            for machine in [audit, other, 0x4000_0003] {
                let flags: &[u64] = if nr == clone_nr(arch).unwrap() as u32 {
                    &samples
                } else {
                    &[0, u64::MAX]
                };
                for &arg0 in flags {
                    assert_eq!(
                        evaluate_with(&program, machine, nr, arg0),
                        threaded_reference(arch, machine, nr, arg0),
                        "{arch}: syscall {nr:#x} flags {arg0:#x} on audit arch {machine:#x}"
                    );
                }
            }
        }
        let clone = clone_nr(arch).unwrap() as u32;
        assert_eq!(evaluate_with(&program, audit, clone, PTHREAD_FLAGS), ALLOW);
        assert_eq!(
            evaluate_with(&program, audit, clone, PTHREAD_FLAGS | 0x1000_0000),
            EPERM,
            "a thread in a new user namespace"
        );
        assert_eq!(evaluate(&program, audit, CLONE3), ENOSYS);
    }
    let filter = BpfFilter::threaded_decoder().unwrap();
    assert_eq!(filter.to_bytes().len(), filter.len() * 8);
    assert!(BpfFilter::threaded_decoder_for("powerpc64").is_err());
}

/// The live checks' child: the test binary itself, run again under a
/// filter with `FOAMY_SECCOMP_PROBE` set. It makes each call, prints one
/// `probe <name> <result>` line per call and exits; run normally it does
/// nothing.
#[test]
fn seccomp_probe_child() {
    let Some(mode) = std::env::var_os("FOAMY_SECCOMP_PROBE") else {
        return;
    };
    let result = |rc: libc::c_long| {
        if rc < 0 {
            match io::Error::last_os_error().raw_os_error() {
                Some(libc::EPERM) => "EPERM".to_string(),
                Some(libc::ENOSYS) => "ENOSYS".to_string(),
                Some(libc::EINVAL) => "EINVAL".to_string(),
                other => format!("errno {other:?}"),
            }
        } else {
            "ok".to_string()
        }
    };
    // A child that a call did start exits at once (it is a copy: no shared
    // memory with the probe).
    let exit_if_child = |rc: libc::c_long| {
        if rc == 0 {
            // SAFETY: _exit in the new process, which owns nothing.
            unsafe { libc::_exit(0) }
        }
        rc
    };
    // 0.6.0's hardening, with arguments the kernel refuses before it would
    // do anything (bad fds, null pointers, an unknown operation or flag), so
    // only the filter answers EPERM.
    let hardening_calls = || {
        // SAFETY: raw syscalls with null pointers and invalid fds; the
        // kernel validates them and fails without side effects.
        unsafe {
            vec![
                (
                    "io_uring_setup",
                    result(libc::syscall(libc::SYS_io_uring_setup, 0, 0)),
                ),
                (
                    "io_uring_enter",
                    result(libc::syscall(libc::SYS_io_uring_enter, -1, 0, 0, 0, 0, 0)),
                ),
                (
                    "io_uring_register",
                    result(libc::syscall(libc::SYS_io_uring_register, -1, 0, 0, 0)),
                ),
                (
                    "add_key",
                    result(libc::syscall(libc::SYS_add_key, 0, 0, 0, 0, 0)),
                ),
                (
                    "request_key",
                    result(libc::syscall(libc::SYS_request_key, 0, 0, 0, 0)),
                ),
                (
                    "keyctl",
                    result(libc::syscall(libc::SYS_keyctl, -1, 0, 0, 0, 0)),
                ),
                // UFFD_USER_MODE_ONLY (allowed without privileges) with an
                // unknown flag: EINVAL.
                (
                    "userfaultfd",
                    result(libc::syscall(libc::SYS_userfaultfd, 1 | 4)),
                ),
            ]
        }
    };
    let mut lines = Vec::new();
    if mode == "decoder-self" {
        // The single-threaded profile can't run the test harness (it
        // starts a thread), so the probe installs it on its own thread,
        // just before the calls.
        install(&BpfFilter::decoder().unwrap().program).unwrap();
        lines.push((
            "thread",
            match std::thread::Builder::new().spawn(|| 7) {
                Ok(_) => "ok".to_string(),
                Err(error) if error.raw_os_error() == Some(libc::EPERM) => "EPERM".to_string(),
                Err(error) => format!("{error}"),
            },
        ));
        lines.extend(hardening_calls());
    } else if mode == "x32" {
        // getpid through the x32 ABI: the filter kills the process.
        // SAFETY: a raw syscall without pointer arguments.
        let rc = unsafe { libc::syscall(39 | X32_SYSCALL_BIT as libc::c_long) };
        lines.push(("x32", result(rc)));
    } else {
        let thread = std::thread::Builder::new().spawn(|| 7).map(|t| t.join());
        let thread = match thread {
            Ok(Ok(7)) => "ok".to_string(),
            Ok(_) => "panicked".to_string(),
            Err(error) => format!("{error}"),
        };
        lines.push(("thread", thread));
        // SAFETY: fork in a probe whose child exits at once.
        let fork = exit_if_child(unsafe { libc::fork() } as libc::c_long);
        if fork > 0 {
            // SAFETY: reaps the child just started.
            unsafe { libc::waitpid(fork as libc::pid_t, std::ptr::null_mut(), 0) };
        }
        lines.push(("fork", result(fork)));
        // The raw clone calls use flags the kernel would refuse (EINVAL), so
        // nothing starts if the filter let them through, and EPERM can only
        // come from the filter. CLONE_SIGHAND without CLONE_VM: a process.
        let clone = |flags: libc::c_int| {
            // SAFETY: clone with null stack and tid pointers; the kernel
            // refuses these flags before it would create anything.
            result(unsafe { libc::syscall(libc::SYS_clone, flags as libc::c_ulong, 0, 0, 0, 0) })
        };
        lines.push(("clone-process", clone(libc::CLONE_SIGHAND)));
        // CLONE_THREAD without CLONE_SIGHAND: the filter lets it pass.
        lines.push(("clone-thread", clone(libc::CLONE_THREAD)));
        lines.push((
            "clone-thread-newuser",
            clone(libc::CLONE_THREAD | libc::CLONE_NEWUSER),
        ));
        // SAFETY: clone3 with a null argument structure of size 0.
        lines.push((
            "clone3",
            result(unsafe { libc::syscall(libc::SYS_clone3, 0, 0) }),
        ));
        // SAFETY: unshare with flags only.
        lines.push((
            "unshare",
            result(unsafe { libc::unshare(libc::CLONE_NEWUSER) } as libc::c_long),
        ));
        // SAFETY: setns on an invalid fd (EBADF unless filtered).
        lines.push((
            "setns",
            result(unsafe { libc::setns(-1, 0) } as libc::c_long),
        ));
        // SAFETY: bpf with an invalid command and no attributes.
        lines.push((
            "bpf",
            result(unsafe { libc::syscall(libc::SYS_bpf, -1, 0, 0) }),
        ));
        lines.extend(hardening_calls());
        #[cfg(target_arch = "x86_64")]
        {
            // SAFETY: the fork syscall; a started child exits at once.
            let rc = exit_if_child(unsafe { libc::syscall(libc::SYS_fork) });
            if rc > 0 {
                // SAFETY: reaps the child just started.
                unsafe { libc::waitpid(rc as libc::pid_t, std::ptr::null_mut(), 0) };
            }
            lines.push(("sys-fork", result(rc)));
        }
    }
    let mut out = String::new();
    for (name, value) in lines {
        out.push_str(&format!("probe {name} {value}\n"));
    }
    io::stdout().write_all(out.as_bytes()).unwrap();
    io::stdout().flush().unwrap();
    std::process::exit(0);
}

/// Runs [`seccomp_probe_child`] in a new process, under `filter` if given;
/// the probe results by name, and the child's output.
fn probe(
    filter: Option<&BpfFilter>,
    mode: &str,
) -> (BTreeMap<String, String>, crate::child::Output) {
    let mut child = Bounded::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "sandbox::tests::seccomp_probe_child",
            "--nocapture",
            "--test-threads=1",
            "-q",
        ])
        .env("FOAMY_SECCOMP_PROBE", mode)
        .timeout(Duration::from_secs(20));
    if let Some(filter) = filter {
        child = child.seccomp(filter);
    }
    let output = child.run().unwrap();
    let results = output
        .stdout_lossy()
        .lines()
        .filter_map(|line| line.strip_prefix("probe "))
        .filter_map(|line| line.split_once(' '))
        .map(|(name, value)| (name.to_string(), value.to_string()))
        .collect();
    (results, output)
}

#[test]
fn threaded_decoder_in_a_child_runs_threads_but_no_processes() {
    let filter = BpfFilter::threaded_decoder().unwrap();
    let (got, output) = probe(Some(&filter), "calls");
    assert!(output.success(), "{output:?}");
    let expect = |name: &str, value: &str| {
        assert_eq!(
            got.get(name).map(String::as_str),
            Some(value),
            "{name}: {got:?}"
        );
    };
    expect("thread", "ok");
    expect("fork", "EPERM");
    expect("clone-process", "EPERM");
    expect("clone-thread", "EINVAL");
    expect("clone-thread-newuser", "EPERM");
    expect("clone3", "ENOSYS");
    expect("unshare", "EPERM");
    expect("setns", "EPERM");
    expect("bpf", "EPERM");
    if cfg!(target_arch = "x86_64") {
        expect("sys-fork", "EPERM");
        let (_, killed) = probe(Some(&filter), "x32");
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(killed.status.signal(), Some(libc::SIGSYS), "{killed:?}");
    }
    // Without a filter the same calls reach the kernel, which answers
    // otherwise: the EPERMs and the ENOSYS above came from the filter.
    let (free, output) = probe(None, "calls");
    assert!(output.success(), "{output:?}");
    for name in ["clone-process", "clone-thread-newuser", "clone3"] {
        assert_eq!(
            free.get(name).map(String::as_str),
            Some("EINVAL"),
            "{name}: {free:?}"
        );
    }
    assert_eq!(free["thread"], "ok");
    assert_eq!(free["fork"], "ok");
}

#[test]
fn decoder_filter_in_a_child_refuses_threads() {
    // The single-threaded profile, for contrast (why the threaded one
    // exists): clone3 and clone are EPERM, so the test harness in the child
    // can't even start the thread it runs the probe on.
    let filter = BpfFilter::decoder().unwrap();
    let (got, output) = probe(Some(&filter), "calls");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        got.is_empty()
            && !output.status.success()
            && stderr.contains("failed to spawn thread")
            && stderr.contains("Operation not permitted"),
        "{output:?}"
    );
}

/// The names [`hardening`] probes (`seccomp_probe_child`'s line names).
const HARDENING_NAMES: [&str; 7] = [
    "io_uring_setup",
    "io_uring_enter",
    "io_uring_register",
    "add_key",
    "request_key",
    "keyctl",
    "userfaultfd",
];

#[test]
fn decoder_profiles_in_a_child_refuse_io_uring_keys_and_userfaultfd() {
    // Threaded profile: installed by Bounded before exec, as in a job.
    let threaded = BpfFilter::threaded_decoder().unwrap();
    let (got, output) = probe(Some(&threaded), "calls");
    assert!(output.success(), "{output:?}");
    for name in HARDENING_NAMES {
        assert_eq!(
            got.get(name).map(String::as_str),
            Some("EPERM"),
            "threaded {name}: {got:?}"
        );
    }
    // Image decoder profile: installed by the probe on its own thread (the
    // test harness needs a thread first), the same program.
    let (got, output) = probe(None, "decoder-self");
    assert!(output.success(), "{output:?}");
    assert_eq!(
        got.get("thread").map(String::as_str),
        Some("EPERM"),
        "{got:?}"
    );
    for name in HARDENING_NAMES {
        assert_eq!(
            got.get(name).map(String::as_str),
            Some("EPERM"),
            "decoder {name}: {got:?}"
        );
    }
    // Unfiltered, the kernel answers each call otherwise (EBADF, EFAULT,
    // EINVAL, EOPNOTSUPP), so those EPERMs came from the filters. Where an
    // administrator disabled io_uring, io_uring_setup is EPERM anyway.
    let (free, output) = probe(None, "calls");
    assert!(output.success(), "{output:?}");
    let io_uring_disabled = std::fs::read_to_string("/proc/sys/kernel/io_uring_disabled")
        .is_ok_and(|value| value.trim() != "0");
    for name in HARDENING_NAMES {
        let value = free.get(name).map(String::as_str);
        assert!(value.is_some(), "{name}: {free:?}");
        if name == "io_uring_setup" && io_uring_disabled {
            continue;
        }
        assert_ne!(value, Some("EPERM"), "{name} unfiltered: {free:?}");
    }
}
