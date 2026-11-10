#!/usr/bin/env python3
# foamy-kit 0.7.0 eb004fb2f3a5ff6bc56fdd1dfba32c3aafcc8905f5f11b53c92370a8e77b9cc4 — do not edit; change foamy-kit and run sync
"""Build and verify a foamy plugin's native helper, from the plugin alone.

foamy-kit's FoamyNative component copies this file into every plugin that
ships a helper, as kit/native/native.py (run through kit/native/build-native.sh),
so rebuilding and verifying the committed binaries needs only the plugin's
own repository at that commit, rustup and Python 3.11 or newer:

  kit/native/build-native.sh .                 # bin/<arch>/<binary> and <crate>/native.pin
  kit/native/build-native.sh . --verify        # clean rebuild, byte-identical to bin/
  kit/native/build-native.sh . --verify --out DIR   # ... and keep the rebuilt files in DIR
  kit/native/build-native.sh . --test          # cargo fmt --check, clippy -D warnings, test

Both arches are static musl builds made with the toolchain that
rust-toolchain.toml pins and the kit's release profile (kit/rust/release.toml).
Cargo output goes to ${FOAMY_NATIVE_CACHE:-~/.cache/foamy-native}/foamy-<plugin>,
never into the plugin. foamy-kit's check.sh imports this module for its
native checks. Standard library only.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

LOCK_NAME = "foamy-kit.lock"
CHECK_NAME = "tests/kit-check.sh"
STAMP_RE = re.compile(r"^(//|#) foamy-kit (\S+) ([0-9a-f]{64}) ")
# Files foamy-kit components place outside kit/ (components.json rootFiles).
# foamy-kit's tests keep this list, tools/kit-check.sh.in and components.json
# in step.
ROOT_FILES = (".github/workflows/verify-native.yml", "rust-toolchain.toml")
WORKFLOW = ".github/workflows/verify-native.yml"


class KitError(Exception):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_stamp(data):
    """(version, hash, body) for a stamped file, or None."""
    lines = data.decode("utf-8", errors="replace").splitlines(keepends=True)
    for index in (0, 1):
        if index < len(lines):
            match = STAMP_RE.match(lines[index])
            if match:
                body = "".join(lines[:index] + lines[index + 1:]).encode("utf-8")
                return match.group(2), match.group(3), body
    return None


# ------------------------------------------------------------- the kit lock

def lock_path_ok(rel):
    """True for a path foamy-kit can own: a normalised relative path under
    kit/, tests/kit-check.sh or a component root file."""
    parts = rel.split("/")
    if rel.startswith("/") or "\\" in rel or any(part in ("", ".", "..") for part in parts):
        return False
    return (parts[0] == "kit" and len(parts) > 1) or rel == CHECK_NAME or rel in ROOT_FILES


def read_lock(plugin):
    """{"version", "components", "files": {rel: sha256}} or None."""
    lock = Path(plugin) / LOCK_NAME
    if not lock.is_file() or lock.is_symlink():
        return None
    info = {"version": None, "components": [], "files": {}}
    for line in lock.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "version":
            info["version"] = parts[1]
        elif len(parts) == 2 and parts[0] == "components":
            info["components"] = [c for c in parts[1].split(",") if c]
        elif len(parts) == 2 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            if not lock_path_ok(parts[1]):
                raise KitError(f"{LOCK_NAME} lists {parts[1]!r}, which is not a path foamy-kit owns")
            info["files"][parts[1]] = parts[0]
    return info


def kit_problems(plugin, lock):
    """The kit files' integrity against foamy-kit.lock, as tests/kit-check.sh
    checks it (without the native helper checks): every listed file present,
    unedited and stamped with the lock's version, and nothing extra in kit/."""
    plugin = Path(plugin)
    problems = []
    if not lock["version"]:
        problems.append(f"{LOCK_NAME} has no version")
    for rel, expected in sorted(lock["files"].items()):
        path = plugin / rel
        if path.is_symlink() or not path.is_file():
            problems.append(f"{rel} is missing or not a regular file")
            continue
        data = path.read_bytes()
        info = read_stamp(data)
        if info is None:
            if sha256(data) != expected:
                problems.append(f"{rel} was edited (hash differs from the lock)")
            continue
        version, stamp_hash, body = info
        if sha256(body) != stamp_hash:
            problems.append(f"{rel} was edited locally")
        if stamp_hash != expected:
            problems.append(f"{rel} stamp differs from the lock")
        if version != lock["version"]:
            problems.append(f"{rel} is stamped {version}, lock says {lock['version']}")
    kit_dir = plugin / "kit"
    if kit_dir.is_dir():
        for path in sorted(kit_dir.rglob("*")):
            rel = path.relative_to(plugin).as_posix()
            if (path.is_file() or path.is_symlink()) and rel not in lock["files"]:
                problems.append(f"{rel} is not part of foamy-kit")
    return problems


# ------------------------------------------------------------ native helpers

NATIVE_COMPONENT = "FoamyNative"
PIN_NAME = "native.pin"
TOOLCHAIN_FILE = "rust-toolchain.toml"
RELEASE_PROFILE = "kit/rust/release.toml"
ROOT_SOURCES = ("Cargo.lock", "Cargo.toml", TOOLCHAIN_FILE)
ARCHES = {"x86_64": "x86_64-unknown-linux-musl", "aarch64": "aarch64-unknown-linux-musl"}
ELF_MACHINES = {"x86_64": 62, "aarch64": 183}
FILE_ARCH = {"x86_64": "x86-64", "aarch64": "ARM aarch64"}
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
SHA_RE = re.compile(r"[0-9a-f]{64}")


def native_pins(plugin):
    """<crate>/native.pin files directly under the plugin root."""
    return sorted(p for p in Path(plugin).glob(f"*/{PIN_NAME}") if p.is_file() and not p.is_symlink())


def read_pin(path):
    info = {"files": {}}
    for line in Path(path).read_text(errors="replace").splitlines():
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        if len(parts) == 2 and SHA_RE.fullmatch(parts[0]):
            info["files"][parts[1]] = parts[0]
        elif len(parts) == 2:
            info[parts[0]] = parts[1]
    return info


def unstamped(data):
    """A file's bytes without its foamy-kit stamp line (as sed deletes it in
    tests/kit-check.sh: lines split on \\n only)."""
    lines = data.split(b"\n")
    for index in (0, 1):
        if index < len(lines) and STAMP_RE.match(lines[index].decode("utf-8", errors="replace")):
            return b"\n".join(lines[:index] + lines[index + 1:])
    return data


def native_sources(plugin, crate):
    """Plugin-relative paths of everything a native build reads: the crate
    (minus native.pin and target/), the vendored kit/rust, the toolchain file
    and the workspace's Cargo.toml and Cargo.lock at the plugin root."""
    plugin = Path(plugin)
    found = set()
    for top in (plugin / crate, plugin / "kit/rust"):
        for dirpath, dirnames, filenames in os.walk(top):
            current = Path(dirpath)
            if current == plugin / crate:
                dirnames[:] = [d for d in dirnames if d != "target"]
            for filename in filenames:
                path = current / filename
                rel = path.relative_to(plugin).as_posix()
                if path.is_symlink() or not path.is_file() or rel == f"{crate}/{PIN_NAME}":
                    continue
                found.add(rel)
    for rel in ROOT_SOURCES:
        if (plugin / rel).is_file() and not (plugin / rel).is_symlink():
            found.add(rel)
    return sorted(found)


def native_source_hash(plugin, crate):
    """sha256 over "<sha256 of body>  <path>\\n" lines, sorted by path; kit files
    are hashed without their stamp, so a kit version bump alone never makes a
    binary stale."""
    plugin = Path(plugin)
    lines = "".join(f"{sha256(unstamped((plugin / rel).read_bytes()))}  {rel}\n" for rel in native_sources(plugin, crate))
    return sha256(lines.encode())


def elf_problem(data, arch):
    """None for a static 64-bit little-endian ELF executable for `arch`."""
    if data[:4] != b"\x7fELF":
        return "is not an ELF executable"
    if len(data) < 64 or data[4] != 2 or data[5] != 1:
        return "is not a 64-bit little-endian ELF"
    e_type, e_machine = struct.unpack_from("<HH", data, 16)
    if e_machine != ELF_MACHINES[arch]:
        return f"is not a 64-bit {arch} ELF (ELF machine {e_machine})"
    entry, phoff = struct.unpack_from("<QQ", data, 24)
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    if e_type not in (2, 3) or entry == 0:
        return "is not an executable"
    for index in range(phnum):
        offset = phoff + index * phentsize
        if offset + 4 > len(data):
            return "has a truncated program header table"
        if struct.unpack_from("<I", data, offset)[0] == 3:  # PT_INTERP
            return "is dynamically linked (it names an ELF interpreter)"
    return None


def file_problem(path, arch):
    """`file`'s view (static ELF of the right arch), when file(1) exists."""
    tool = shutil.which("file")
    if not tool:
        return None
    out = subprocess.run([tool, "-b", str(path)], capture_output=True, text=True, timeout=30).stdout
    if "ELF 64-bit LSB" not in out or FILE_ARCH[arch] not in out:
        return f"is not a 64-bit {arch} ELF according to file(1): {out.strip()}"
    if "statically linked" not in out and "static-pie linked" not in out:
        return f"is not statically linked according to file(1): {out.strip()}"
    return None


def binary_problems(plugin, rel, arch, expected):
    path = Path(plugin) / rel
    if path.is_symlink() or not path.is_file():
        return [f"{rel} is missing or not a regular file"]
    problems = []
    if not path.stat().st_mode & stat.S_IXUSR:
        problems.append(f"{rel} is not executable")
    data = path.read_bytes()
    if sha256(data) != expected:
        problems.append(f"{rel} checksum differs from native.pin")
    reason = elf_problem(data, arch) or file_problem(path, arch)
    if reason:
        problems.append(f"{rel} {reason}")
    return problems


def verify_native(plugin, lock):
    plugin = Path(plugin)
    problems = []
    pins = native_pins(plugin)
    synced = bool(lock) and NATIVE_COMPONENT in lock["components"]
    if synced and not pins:
        problems.append(f"{NATIVE_COMPONENT} is synced but no <crate>/{PIN_NAME} exists (run kit/native/build-native.sh .)")
    for pin_path in pins:
        crate = pin_path.parent.name
        label = f"{crate}/{PIN_NAME}"
        pin = read_pin(pin_path)
        if not synced:
            problems.append(f"{label} exists but {NATIVE_COMPONENT} is not synced (sync.sh --add {NATIVE_COMPONENT})")
        if pin.get("crate") != crate:
            problems.append(f"{label} names crate {pin.get('crate')!r}, expected {crate!r}")
        binary = pin.get("binary", "")
        if not NAME_RE.fullmatch(binary):
            problems.append(f"{label} has no valid binary name")
            continue
        wanted = {f"bin/{arch}/{binary}": arch for arch in ARCHES}
        for rel, arch in wanted.items():
            if rel not in pin["files"]:
                problems.append(f"{label} has no checksum for {rel}")
            else:
                problems += binary_problems(plugin, rel, arch, pin["files"][rel])
        for rel in sorted(set(pin["files"]) - set(wanted)):
            problems.append(f"{label} lists unexpected file {rel}")
        if native_source_hash(plugin, crate) != pin.get("source"):
            problems.append(f"{binary} is stale: {crate}/, kit/rust, Cargo.toml, Cargo.lock or {TOOLCHAIN_FILE} "
                            f"changed since it was built (run kit/native/build-native.sh .)")
    return problems


# --------------------------------------------------------------- native build

def plugin_short_name(plugin):
    """`power` for a plugin whose manifest id is `foamy.power`."""
    plugin_id = json.loads((Path(plugin) / "manifest.json").read_text()).get("id", "")
    match = re.fullmatch(r"foamy\.([a-z0-9][a-z0-9-]*)", plugin_id)
    if not match:
        raise KitError(f"manifest id {plugin_id!r} is not foamy.<name>")
    return match.group(1)


def native_cache():
    base = os.environ.get("FOAMY_NATIVE_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "foamy-native")
    return Path(base).resolve()


def resolve_native(plugin, crate=None, binary=None):
    """(crate dir, binary name) from the options, an existing native.pin, or
    the defaults `native/` and `foamy-<plugin>-helper`."""
    plugin = Path(plugin)
    pins = native_pins(plugin)
    if crate is None:
        if len(pins) > 1:
            raise KitError("several crates have a native.pin (" + ", ".join(p.parent.name for p in pins) + "); pass --crate")
        crate = pins[0].parent.name if pins else "native"
    crate = crate.strip("/")
    if not NAME_RE.fullmatch(crate) or crate in ("kit", "bin", "tests"):
        raise KitError(f"invalid crate directory {crate!r} (one directory directly under the plugin)")
    pin = read_pin(plugin / crate / PIN_NAME) if (plugin / crate / PIN_NAME).is_file() else {}
    binary = binary or pin.get("binary") or f"foamy-{plugin_short_name(plugin)}-helper"
    if not NAME_RE.fullmatch(binary):
        raise KitError(f"invalid binary name {binary!r}")
    return crate, binary


def toolchain_channel(plugin):
    path = Path(plugin) / TOOLCHAIN_FILE
    try:
        channel = tomllib.loads(path.read_text())["toolchain"]["channel"]
    except (OSError, KeyError, tomllib.TOMLDecodeError) as error:
        raise KitError(f"{TOOLCHAIN_FILE}: no toolchain channel ({error}); run sync.sh --add {NATIVE_COMPONENT}")
    return channel


WORKSPACE_EXAMPLE = '[workspace]\nmembers = ["{crate}"]\nexclude = ["kit"]\nresolver = "3"'


def read_toml(path):
    try:
        return tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise KitError(f"{path.name}: {error}")


def native_preflight(plugin, crate):
    """Refuse a build that couldn't be reproduced: kit files edited or not
    synced, no workspace at the plugin root, no Cargo.lock, or a [profile]
    outside the kit's release profile."""
    lock = read_lock(plugin)
    if not lock or NATIVE_COMPONENT not in lock["components"]:
        raise KitError(f"{NATIVE_COMPONENT} is not synced; run sync.sh {plugin} --add {NATIVE_COMPONENT}")
    problems = kit_problems(plugin, lock)
    if problems:
        raise KitError("kit files are not intact (run sync.sh):\n  " + "\n  ".join(problems))
    if not (plugin / crate / "Cargo.toml").is_file():
        raise KitError(f"{crate}/Cargo.toml not found")
    # The workspace root is the plugin root, so cargo hashes the vendored
    # kit/rust crate by its path relative to the plugin, not its absolute
    # path: every checkout then builds the same bytes.
    example = WORKSPACE_EXAMPLE.format(crate=crate)
    if not (plugin / "Cargo.toml").is_file():
        raise KitError(f"no Cargo.toml at the plugin root; create it with:\n{example}")
    root = read_toml(plugin / "Cargo.toml")
    workspace = root.get("workspace")
    if not isinstance(workspace, dict) or "package" in root:
        raise KitError(f"the plugin's Cargo.toml must be a virtual workspace manifest:\n{example}")
    if crate not in workspace.get("members", []) or "kit" not in workspace.get("exclude", []):
        raise KitError(f"the plugin's Cargo.toml must list {crate!r} in members and 'kit' in exclude:\n{example}")
    for rel in ("Cargo.toml", f"{crate}/Cargo.toml"):
        if "profile" in read_toml(plugin / rel):
            raise KitError(f"{rel} declares [profile]; remove it, the kit's {RELEASE_PROFILE} is the release profile")
    if "workspace" in read_toml(plugin / crate / "Cargo.toml"):
        raise KitError(f"{crate}/Cargo.toml declares [workspace]; the workspace is the plugin's root Cargo.toml")
    # Cargo reads .cargo/config(.toml) from the working directory (the crate
    # dir) and every parent. One inside the plugin is contributor content that
    # native.pin doesn't hash, and it can set a rustc wrapper or flags that
    # change both the build and --verify (the environment is already scrubbed).
    configs = []
    here = (plugin / crate).resolve()
    top = plugin.resolve()
    while True:
        for name in ("config", "config.toml"):
            candidate = here / ".cargo" / name
            if candidate.exists() or candidate.is_symlink():
                configs.append(candidate.relative_to(top).as_posix())
        if here == top or top not in here.parents:
            break
        here = here.parent
    if configs:
        raise KitError("Cargo configuration inside the plugin isn't allowed (it isn't part of native.pin and can "
                       "change the build); the kit's release profile and build flags are the only settings: "
                       + ", ".join(configs))
    # native_source_hash skips symlinks, so a symlinked build input (or
    # directory) would let its target change without the pin noticing.
    linked = []
    for top in (plugin / crate, plugin / "kit/rust"):
        for dirpath, dirnames, filenames in os.walk(top):
            current = Path(dirpath)
            if current == plugin / crate:
                dirnames[:] = [d for d in dirnames if d != "target"]
            for name in dirnames + filenames:
                if (current / name).is_symlink():
                    linked.append((current / name).relative_to(plugin).as_posix())
    linked += [rel for rel in ROOT_SOURCES if (plugin / rel).is_symlink()]
    if (plugin / crate).is_symlink():
        linked.append(crate)
    if linked:
        raise KitError("symlinked build inputs aren't allowed (native.pin hashes files, not link targets): "
                       + ", ".join(sorted(linked)))
    outside = path_dependencies_outside(plugin, crate)
    if outside:
        raise KitError("path dependencies outside the hashed sources (the crate dir and kit/rust), so native.pin "
                       "couldn't tell when they change; move them into " + crate + "/ or use a published crate:\n  "
                       + "\n  ".join(outside))
    if not (plugin / "Cargo.lock").is_file():
        raise KitError("Cargo.lock is missing at the plugin root; run `cargo generate-lockfile` there and commit it")
    if (plugin / crate / "Cargo.lock").exists():
        raise KitError(f"{crate}/Cargo.lock is unused (the lock file lives at the plugin root); remove it")


def path_dependencies_outside(plugin, crate):
    """`path = …` dependencies (any table: dependencies, dev-, build-,
    target-specific, workspace.dependencies, patch, replace) in the root and
    crate manifests that resolve outside the crate dir and kit/rust, which
    native_source_hash covers. ["<manifest>: <name> = <path>", …]."""
    plugin = Path(plugin).resolve()
    allowed = [(plugin / crate).resolve(), (plugin / "kit/rust").resolve()]
    found = []

    def walk(table, base, manifest, name=""):
        if not isinstance(table, dict):
            return
        path = table.get("path")
        if isinstance(path, str) and name:
            target = (base / path).resolve()
            if not any(target == root or root in target.parents for root in allowed):
                found.append(f"{manifest}: {name} = {path!r}")
        for key, value in table.items():
            if isinstance(value, dict):
                walk(value, base, manifest, key)

    for rel in ("Cargo.toml", f"{crate}/Cargo.toml"):
        manifest = plugin / rel
        data = read_toml(manifest)
        # [workspace] members/exclude are not dependencies.
        tables = {k: v for k, v in data.items() if k not in ("package", "workspace", "lib", "bin", "profile")}
        if isinstance(data.get("workspace"), dict):
            tables["workspace.dependencies"] = data["workspace"].get("dependencies", {})
        for key, value in tables.items():
            walk(value, manifest.parent, rel, key if isinstance(value, dict) and "path" in value else "")
    return found


def cargo_env(target_dir, channel, flags=None, linker_triples=()):
    """The environment for cargo: the pinned toolchain, our target dir, and
    nothing from the caller that changes code generation."""
    env = {key: value for key, value in os.environ.items()
           if key not in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_RUSTFLAGS", "RUSTC", "RUSTC_WRAPPER",
                          "RUSTC_WORKSPACE_WRAPPER", "CARGO_BUILD_TARGET", "CARGO_BUILD_TARGET_DIR", "CARGO_INCREMENTAL",
                          "CARGO_BUILD_RUSTC", "CARGO_BUILD_RUSTC_WRAPPER", "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER")
           and not key.startswith(("CARGO_PROFILE_", "CARGO_TARGET_"))}
    env.update(RUSTUP_TOOLCHAIN=channel, CARGO_TARGET_DIR=str(target_dir), CARGO_INCREMENTAL="0")
    if flags is not None:
        env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(flags)
    for triple in linker_triples:
        env[f"CARGO_TARGET_{triple.upper().replace('-', '_')}_LINKER"] = "rust-lld"
    return env


def check_toolchain(env, channel, cwd):
    try:
        out = subprocess.run(["rustc", "--version"], env=env, cwd=cwd, capture_output=True, text=True, timeout=60)
    except OSError:
        raise KitError("rustc not found; install rustup (https://rustup.rs)")
    if out.returncode != 0 or not out.stdout.startswith(f"rustc {channel} "):
        raise KitError(f"rustc is {out.stdout.strip() or out.stderr.strip()!r}, expected {channel} "
                       f"(rustup toolchain install {channel}, with the musl targets from {TOOLCHAIN_FILE})")
    return out.stdout.strip()


def build_native(plugin, crate, binary, channel, target_dir):
    """Builds both arches into target_dir; {arch: bytes}."""
    plugin = Path(plugin)
    crate_dir = plugin / crate
    home = Path.home()
    cargo_home = Path(os.environ.get("CARGO_HOME") or home / ".cargo").resolve()
    rustup_home = Path(os.environ.get("RUSTUP_HOME") or home / ".rustup").resolve()
    # Later remaps win: general prefixes first. Paths end up relative to the
    # plugin, so any checkout (live, worktree, another machine) builds the
    # same bytes.
    flags = [
        "-C", "link-self-contained=yes",
        "-C", "link-arg=--build-id=none",
        f"--remap-path-prefix={cargo_home}=/cargo",
        f"--remap-path-prefix={rustup_home}=/rustup",
        f"--remap-path-prefix={target_dir}=/target",
        f"--remap-path-prefix={plugin}=.",
        f"--remap-path-prefix={plugin / 'kit/rust'}=kit/rust",
        f"--remap-path-prefix={crate_dir}=.",
    ]
    env = cargo_env(target_dir, channel, flags, ARCHES.values())
    check_toolchain(env, channel, crate_dir)
    built = {}
    for arch, triple in ARCHES.items():
        command = ["cargo", "build", "--locked", "--release", "--target", triple, "--bin", binary,
                   "--manifest-path", str(crate_dir / "Cargo.toml"), "--config", str(plugin / RELEASE_PROFILE)]
        result = subprocess.run(command, env=env, cwd=crate_dir)
        if result.returncode != 0:
            raise KitError(f"cargo build for {triple} failed (exit {result.returncode})")
        data = (Path(target_dir) / triple / "release" / binary).read_bytes()
        reason = elf_problem(data, arch)
        if reason:
            raise KitError(f"the {arch} build {reason}")
        built[arch] = data
    return built


def open_contained_dir(plugin, rel_dir):
    """An O_DIRECTORY fd for plugin/rel_dir, walked one component at a time
    with O_NOFOLLOW (creating missing ones, 0755), so no symlinked parent
    (bin -> elsewhere, bin/x86_64 -> elsewhere) can lead a write outside the
    plugin. The caller closes it."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(plugin, flags)
    try:
        for part in Path(rel_dir).parts:
            if part in ("", ".", ".."):
                raise KitError(f"invalid directory {rel_dir!r}")
            try:
                next_fd = os.open(part, flags, dir_fd=fd)
            except FileNotFoundError:
                os.mkdir(part, 0o755, dir_fd=fd)
                next_fd = os.open(part, flags, dir_fd=fd)
            except OSError as error:
                raise KitError(f"{rel_dir}: {part} is not a plain directory inside the plugin "
                               f"(a symlink or a file?): {error.strerror}") from None
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def install_atomic(plugin, rel, data, mode):
    """Writes data to plugin/rel through a temp file in the same directory and
    a rename, so the running shell never sees a partial file. Every directory
    is opened without following symlinks and the file is replaced by name in
    that directory, so nothing outside the plugin is written. No-op when equal."""
    rel = Path(rel)
    dir_fd = open_contained_dir(Path(plugin), rel.parent)
    name = rel.name
    try:
        try:
            current = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
        except OSError:
            current = None
        if current is not None:
            try:
                info = os.fstat(current)
                if stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == mode and info.st_size == len(data):
                    with os.fdopen(os.dup(current), "rb") as stream:
                        if stream.read() == data:
                            return False
            finally:
                os.close(current)
        temp = None
        for attempt in range(100):
            candidate = f".{name}.{os.getpid()}.{attempt}"
            try:
                fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600,
                             dir_fd=dir_fd)
            except FileExistsError:
                continue
            temp = candidate
            break
        if temp is None:
            raise KitError(f"{rel}: could not create a temporary file")
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fchmod(stream.fileno(), mode)
                os.fsync(stream.fileno())
            os.replace(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            os.fsync(dir_fd)
        except BaseException:
            try:
                os.unlink(temp, dir_fd=dir_fd)
            except OSError:
                pass
            raise
        return True
    finally:
        os.close(dir_fd)


def export_rebuilt(out_dir, binary, built):
    """Writes each rebuilt binary to out_dir/<arch>/<binary> as a new file
    (mode 0755). The arch directories are opened without following symlinks
    and an existing file is refused, so --out can never write through a link
    into the plugin (bin/) or replace an earlier export."""
    out_dir.mkdir(parents=True, exist_ok=True)
    for arch, data in sorted(built.items()):
        try:
            dir_fd = open_contained_dir(out_dir, arch)
        except KitError:
            raise KitError(f"--out: {out_dir / arch} is not a plain directory (a symlink?); use an empty directory") from None
        try:
            try:
                fd = os.open(binary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o755,
                             dir_fd=dir_fd)
            except FileExistsError:
                raise KitError(f"--out: {out_dir / arch / binary} already exists; use an empty directory") from None
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                os.fchmod(stream.fileno(), 0o755)
        finally:
            os.close(dir_fd)
        print(f"{out_dir / arch / binary}: {len(data)} bytes, sha256 {sha256(data)}")


def pin_bytes(crate, binary, channel, source, built, kit):
    lines = [
        f"# {PIN_NAME}: written by kit/native/build-native.sh; do not edit.",
        "# check.sh and tests/kit-check.sh verify bin/<arch>/<binary> against it and",
        "# report the binaries stale when `source` no longer matches the crate, kit/rust,",
        f"# Cargo.toml, Cargo.lock and {TOOLCHAIN_FILE}. Rebuild: kit/native/build-native.sh .",
        f"crate {crate}",
        f"binary {binary}",
        f"toolchain {channel}",
        f"kit {kit}",
        f"source {source}",
    ]
    lines += [f"{sha256(built[arch])}  bin/{arch}/{binary}" for arch in sorted(built)]
    return ("\n".join(lines) + "\n").encode()


def cmd_native(args):
    plugin = Path(args.plugin).resolve()
    try:
        if not (plugin / "manifest.json").is_file():
            raise KitError(f"{plugin}: not a plugin (no manifest.json)")
        name = plugin_short_name(plugin)
        crate, binary = resolve_native(plugin, args.crate, args.bin)
        native_preflight(plugin, crate)
        channel = toolchain_channel(plugin)
        cache = native_cache()
        if cache == plugin or plugin in cache.parents:
            raise KitError(f"the cargo cache {cache} is inside the plugin; cargo output never goes into a plugin folder")
        target_dir = cache / f"foamy-{name}"
        crate_dir = plugin / crate
        out_dir = None
        if getattr(args, "out", None):
            if not args.verify:
                raise KitError("--out goes with --verify")
            out_dir = Path(args.out).resolve()
            if out_dir == plugin or plugin in out_dir.parents:
                raise KitError(f"--out {out_dir} is inside the plugin; the rebuilt binaries go outside it")
        if args.test:
            env = cargo_env(target_dir, channel)
            check_toolchain(env, channel, crate_dir)
            manifest = ["--manifest-path", str(crate_dir / "Cargo.toml")]
            for step in (["cargo", "fmt", "--check", *manifest],
                         ["cargo", "clippy", "--locked", "--all-targets", *manifest, "--", "-D", "warnings"],
                         ["cargo", "test", "--locked", *manifest]):
                print("+ " + " ".join(step[:3]), flush=True)
                if subprocess.run(step, env=env, cwd=crate_dir).returncode != 0:
                    raise KitError(f"{' '.join(step[:2])} failed")
            print(f"{plugin.name}: {crate}/ fmt, clippy and tests OK")
            return 0
        if args.verify:
            pin_path = crate_dir / PIN_NAME
            if not pin_path.is_file():
                raise KitError(f"no {crate}/{PIN_NAME}; build first")
            pin = read_pin(pin_path)
            problems = verify_native(plugin, read_lock(plugin))
            source = native_source_hash(plugin, crate)
            cache.mkdir(parents=True, exist_ok=True)
            fresh = Path(tempfile.mkdtemp(prefix=f"foamy-{name}-verify-", dir=cache))
            try:
                built = build_native(plugin, crate, binary, channel, fresh)
            finally:
                shutil.rmtree(fresh, ignore_errors=True)
            if native_source_hash(plugin, crate) != source:
                raise KitError(f"{crate}/, kit/rust or the workspace files changed during the verify build; re-run it")
            for arch, data in sorted(built.items()):
                rel = f"bin/{arch}/{binary}"
                committed = (plugin / rel).read_bytes() if (plugin / rel).is_file() else b""
                if data != committed:
                    problems.append(f"{rel}: a clean rebuild differs from the committed binary ({sha256(data)[:16]}… vs {sha256(committed)[:16]}…)")
                else:
                    print(f"{rel}: byte-identical to a clean rebuild ({len(data)} bytes, sha256 {sha256(data)[:16]}…)")
            if out_dir is not None:
                # The rebuilt files themselves, for CI to attest and publish,
                # written only after the comparison above read bin/, and kept
                # even when they differ, so a mismatch can be inspected.
                export_rebuilt(out_dir, binary, built)
            if pin.get("toolchain") != channel:
                problems.append(f"{crate}/{PIN_NAME} says toolchain {pin.get('toolchain')}, {TOOLCHAIN_FILE} says {channel}")
            if pin.get("source") != source:
                problems.append(f"{crate}/{PIN_NAME} source hash is stale")
            if problems:
                raise KitError("verify failed:\n  " + "\n  ".join(dict.fromkeys(problems)))
            print(f"{plugin.name}: verify OK ({binary}, {channel}, both arches reproducible)")
            return 0
        # Hash before and after: an edit while cargo runs (or between the two
        # arches) would otherwise pin binaries to sources they weren't built from.
        source = native_source_hash(plugin, crate)
        built = build_native(plugin, crate, binary, channel, target_dir)
        if native_source_hash(plugin, crate) != source:
            raise KitError(f"{crate}/, kit/rust or the workspace files changed during the build; "
                           "nothing was installed, re-run the build")
        # Every target directory must be a plain directory inside the plugin
        # before anything is written (install_atomic checks again, race-free).
        for rel in [f"bin/{arch}" for arch in sorted(built)] + [crate]:
            os.close(open_contained_dir(plugin, rel))
        changed = [f"bin/{arch}/{binary}" for arch, data in sorted(built.items())
                   if install_atomic(plugin, f"bin/{arch}/{binary}", data, 0o755)]
        if install_atomic(plugin, f"{crate}/{PIN_NAME}", pin_bytes(crate, binary, channel, source, built, read_lock(plugin)["version"]), 0o644):
            changed.append(f"{crate}/{PIN_NAME}")
        sizes = ", ".join(f"{arch} {len(data)} bytes" for arch, data in sorted(built.items()))
        print(f"{plugin.name}: {binary} ({channel}): {sizes}; " + (f"updated {', '.join(changed)}" if changed else "up to date"))
        return 0
    except KitError as error:
        print(f"build-native: {error}", file=sys.stderr)
        return 1




def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="build-native.sh",
        description="Build both arches of a foamy plugin's native helper (static musl) into bin/<arch>/ "
                    "and write <crate>/native.pin; or verify or test them.")
    parser.add_argument("plugin", help="the plugin directory (. from its root)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--verify", action="store_true",
                      help="rebuild in a fresh target dir and compare with the committed binaries")
    mode.add_argument("--test", action="store_true", help="cargo fmt --check, clippy -D warnings and test for the crate")
    parser.add_argument("--out", metavar="DIR", help="with --verify: also write the rebuilt binaries to DIR/<arch>/<binary>")
    parser.add_argument("--crate", help="crate directory (default: the one with a native.pin, else native)")
    parser.add_argument("--bin", help="binary name (default: native.pin's, else foamy-<plugin>-helper)")
    return cmd_native(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
