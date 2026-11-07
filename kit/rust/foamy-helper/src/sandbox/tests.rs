// foamy-kit 0.5.2 78ba4abf76f4bedcb2fcfb211a0b31af68055b15f6e093bf28cb860caec0be42 — do not edit; change foamy-kit and run sync
use super::*;
use std::time::Duration;

const ALLOW: u32 = 0x7fff_0000;
const EPERM: u32 = 0x0005_0001;
const KILL: u32 = SECCOMP_RET_KILL_PROCESS;
const AUDIT_X86_64: u32 = 0xc000_003e;
const AUDIT_AARCH64: u32 = 0xc000_00b7;

/// artwork.py's `decoder_filter()`, instruction for instruction.
fn python_reference(arch: &str) -> Vec<sock_filter> {
    let (audit, denied): (u32, &[u32]) = match arch {
        "x86_64" => (AUDIT_X86_64, &[56, 57, 58, 101, 165, 272, 308, 321, 435]),
        _ => (AUDIT_AARCH64, &[40, 97, 117, 220, 268, 280, 435]),
    };
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
    for &nr in denied {
        program.extend([insn(0x15, 0, 1, nr), insn(0x06, 0, 0, EPERM)]);
    }
    program.push(insn(0x06, 0, 0, ALLOW));
    program
}

/// A classic BPF interpreter for what seccomp filters use here: the result
/// for syscall `nr` on architecture `audit`.
fn evaluate(program: &[sock_filter], audit: u32, nr: u32) -> u32 {
    let (mut pc, mut a) = (0usize, 0u32);
    for _ in 0..10_000 {
        let insn = &program[pc];
        pc += 1;
        match insn.code {
            0x20 => {
                a = match insn.k {
                    0 => nr,
                    4 => audit,
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
    let spawn = run("/usr/bin/true && echo spawned; exit 0");
    assert!(
        spawn.stdout.is_empty(),
        "the decoder can't start processes: {spawn:?}"
    );
}
