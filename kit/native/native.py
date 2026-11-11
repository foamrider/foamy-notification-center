#!/usr/bin/env python3
# foamy-kit 0.9.0 2003384e902a522533e61943c25b8e148d38fcef6442b9f61db7a69e71823905 — do not edit; change foamy-kit and run sync
"""Build and verify a foamy plugin's native helper, from the plugin alone.

foamy-kit's FoamyNative component copies this file into every plugin that
ships a helper, as kit/native/native.py (run through kit/native/build-native.sh),
so rebuilding and verifying the committed binaries needs only the plugin's
own repository at that commit, rustup and Python 3.11 or newer:

  kit/native/build-native.sh .                 # bin/<arch>/<binary> and <crate>/native.pin
  kit/native/build-native.sh . --verify        # clean rebuild, byte-identical to bin/
  kit/native/build-native.sh . --verify --out DIR   # ... and keep the rebuilt files in DIR
  kit/native/build-native.sh . --test          # cargo fmt --check, clippy -D warnings, test
  kit/native/build-native.sh . --notices       # only rewrite THIRD_PARTY_NOTICES.md

The build and --verify also write / check THIRD_PARTY_NOTICES.md at the
plugin root: the license texts and copyright notices of the third-party code
linked into the binaries (see "third-party notices" below).

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
    kit/, tests/kit-check.sh, REVIEW.md or a component root file."""
    parts = rel.split("/")
    if rel.startswith("/") or "\\" in rel or any(part in ("", ".", "..") for part in parts):
        return False
    return (parts[0] == "kit" and len(parts) > 1) or rel in (CHECK_NAME, "REVIEW.md") or rel in ROOT_FILES


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
    return problems + notices_problems(plugin, pins)


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


def cargo_home():
    return Path(os.environ.get("CARGO_HOME") or Path.home() / ".cargo").resolve()


def build_flags(plugin, crate, target_dir):
    """The rustc flags of every native build (and of the dependency graph the
    notices are made from, so target cfgs are evaluated the same way)."""
    plugin = Path(plugin)
    rustup_home = Path(os.environ.get("RUSTUP_HOME") or Path.home() / ".rustup").resolve()
    # Later remaps win: general prefixes first. Paths end up relative to the
    # plugin, so any checkout (live, worktree, another machine) builds the
    # same bytes.
    return [
        "-C", "link-self-contained=yes",
        "-C", "link-arg=--build-id=none",
        f"--remap-path-prefix={cargo_home()}=/cargo",
        f"--remap-path-prefix={rustup_home}=/rustup",
        f"--remap-path-prefix={target_dir}=/target",
        f"--remap-path-prefix={plugin}=.",
        f"--remap-path-prefix={plugin / 'kit/rust'}=kit/rust",
        f"--remap-path-prefix={plugin / crate}=.",
    ]


def build_native(plugin, crate, binary, channel, target_dir):
    """Builds both arches into target_dir; {arch: bytes}."""
    plugin = Path(plugin)
    crate_dir = plugin / crate
    env = cargo_env(target_dir, channel, build_flags(plugin, crate, target_dir), ARCHES.values())
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


# ------------------------------------------------------ third-party notices
#
# THIRD_PARTY_NOTICES.md at the plugin root maps the code statically linked
# into each pinned binary to the license texts and copyright notices that
# code ships. It is generated with the binaries (never by hand), from
# Cargo.lock, the crate archives in the cargo registry (each checked against
# its Cargo.lock checksum) and the pinned toolchain, so it is deterministic:
# --verify regenerates it and fails when the committed file differs. It is
# not a build input (native_sources leaves the plugin root's files out), so
# writing it never makes the binaries stale.

NOTICES_NAME = "THIRD_PARTY_NOTICES.md"
NOTICES_TITLE = "# Third-party notices: native helpers"
TREE_LINE_RE = re.compile(r"(\S+) v(\S+)(?: \((.+)\))?")
NAME_VERSION_RE = re.compile(r"(.+?)-(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]*)?)")
NOTICE_FILE_RE = re.compile(r"(?i)(licen[cs]e|copying|notice|copyright|unlicen[cs]e)([-._ ].*)?")
NOT_NOTICE_SUFFIXES = (".rs", ".toml", ".json", ".yml", ".yaml", ".sh", ".py", ".html", ".css", ".js", ".lock")
SOURCE_SUFFIXES = (".rs", ".c", ".h", ".s", ".S", ".asm", ".inc", ".cc", ".cpp")
# Not compiled into a binary, so their file headers are not scanned.
SOURCE_SKIP_DIRS = {"tests", "test", "benches", "bench", "examples", "example", "fuzz", "testdata", "docs", "doc",
                    ".github", "ci", "admin", "scripts"}
HEADER_LINES = 40
COPYRIGHT_LINE_RE = re.compile(r"(?i)(copyright\b|\(c\)\s*\d|©)")
NOT_COPYRIGHT_RE = re.compile(r"(?i)copyright\s+(notice|holder|owner|and\b|law|claim|license|statement|\(c\)\s*<)")
SPDX_LINE_RE = re.compile(r"SPDX-License-Identifier:\s*([A-Za-z0-9.+()\s-]+)")
ELF_CRATE_RE = re.compile(rb"/cargo/registry/src/[^/\x00]+/([A-Za-z0-9_.+-]+)/")
ELF_STD_DEP_RE = re.compile(rb"/rust/deps/([A-Za-z0-9_.+-]+)/")
ELF_STD_RE = re.compile(rb"/rustc/[0-9a-f]{40}/library/([a-z_]+)/")
# Sysroot crates of the musl targets that live in the Rust repository
# (library/): covered by the toolchain's "in-tree" notices.
SYSROOT_IN_TREE = {"alloc", "compiler_builtins", "core", "panic_abort", "panic_unwind", "proc_macro",
                   "profiler_builtins", "rustc_std_workspace_alloc", "rustc_std_workspace_core",
                   "rustc_std_workspace_std", "std", "std_detect", "sysroot", "test", "unwind"}
# Sysroot crates a release helper never links, and why.
SYSROOT_NOT_LINKED = {
    "test": "the test harness",
    "getopts": "used only by the test harness",
    "proc_macro": "the compiler's proc-macro bridge",
    "rustc_literal_escaper": "used only by proc_macro",
    "profiler_builtins": "only for -C instrument-coverage / profile-generate builds",
    "panic_unwind": 'the release profile is panic = "abort" (panic_abort is linked instead)',
}
# The standard library's crates.io dependencies for each pinned toolchain:
# (name, version, sha256 of the .crate), the registry packages of
# library/Cargo.lock in that toolchain's rust-src component (for 1.99.1:
# rust-src-1.99.1.tar.xz, sha256 e485a88c45db546b73571df7bebfcb4454ba4fb552c492e25fc5b00eeb5bf22d as
# rustup's channel manifest gives it; library/Cargo.lock sha256
# 53d9ccff0c906de434b65af90d5c30063894b940fc839261f1fb06ef2e69e3d3). The build needs only the minimal
# profile, so rust-src is usually absent; when it is installed, its
# Cargo.lock is read instead and must agree with this table. A new toolchain
# needs its entry (or rust-src installed) before notices can be generated.
STD_LOCKS = {
    "1.99.1": (
        ("addr2line", "0.27.1", "e567177890eb1617b1f774005b66b26b2377afd138a2ca37aae7d8f0c81429d4"),
        ("adler2", "2.0.1", "320119579fcad9c21884f5c4861d16174d0e06250625266f50fe6898340abefa"),
        ("cc", "1.2.0", "1aeb932158bd710538c73702db6945cb68a8fb08c519e6e12706b94263b36db8"),
        ("cfg-if", "1.0.4", "9330f8b2ff13f34540b44e946ef35111825727b38d33286ef986142615121801"),
        ("dlmalloc", "0.2.14", "ad5208a115eaba24916f7456929832e310a81518c641f93fee4f89aa93aa3675"),
        ("foldhash", "0.2.0", "77ce24cb58228fbb8aa041425bb1050850ac19177686ea6e0f41a70416f56fdb"),
        ("fortanix-sgx-abi", "0.6.1", "5efc85edd5b83e8394f4371dd0da6859dff63dd387dab8568fece6af4cde6f84"),
        ("getopts", "0.2.24", "cfe4fbac503b8d1f88e6676011885f34b7174f46e59956bba534ba83abded4df"),
        ("gimli", "0.34.0", "1033caf0b349c518623b5396bfb2cf0bddf44f0306d543a250e5743297aafd10"),
        ("hashbrown", "0.17.1", "ed5909b6e89a2db4456e54cd5f673791d7eca6732202bbf2a9cc504fe2f9b84a"),
        ("hermit-abi", "0.5.2", "fc0fef456e4baa96da950455cd02c081ca953b141298e41db3fc7e36b1da849c"),
        ("libc", "0.2.189", "3eaf3ede3fee6db1a4c2ee091bf8a8b4dccdc6d17f656fb07896ee72867612f2"),
        ("memchr", "2.8.3", "cf8baf1c55e62ffcace7a9f06f4bd9cd3f0c4beb022d3b367256b91b87513d98"),
        ("miniz_oxide", "0.9.1", "b63fbc4a50860e98e7b2aa7804ded1db5cbc3aff9193adaff57a6931bf7c4b4c"),
        ("moto-rt", "0.16.4", "0aadbab5a5ca5a01ec1ff4bc03c2c3a7643f0e1d97ad5a4a5b58ce78504e17da"),
        ("object", "0.39.1", "2e5a6c098c7a3b6547378093f5cc30bc54fd361ce711e05293a5cc589562739b"),
        ("r-efi", "5.3.0", "69cdb34c158ceb288df11e18b4bd39de994f6657d83847bdffdbd7f346754b0f"),
        ("r-efi-alloc", "2.1.0", "dc2f58ef3ca9bb0f9c44d9aa8537601bcd3df94cc9314a40178cadf7d4466354"),
        ("rand", "0.9.5", "b9ef1d0d795eb7d84685bca4f72f3649f064e6641543d3a8c415898726a57b41"),
        ("rand_core", "0.9.5", "76afc826de14238e6e8c374ddcc1fa19e374fd8dd986b0d2af0d02377261d83c"),
        ("rand_xorshift", "0.4.0", "513962919efc330f829edb2535844d1b912b0fbe2ca165d613e4e8788bb05a5a"),
        ("rustc-demangle", "0.1.28", "b74b56ffa8bb2830709a538c2cbcae9aa062db0d2a42563bfb09bdaae44020eb"),
        ("rustc-literal-escaper", "0.0.8", "bfe6f213fb658c8fb95baabd5420393438cf5a98d707f5dd701d9197c705f71e"),
        ("shlex", "1.3.0", "0fda2ff0d084019ba4d7c6f371c95d8fd75ce3524c3cb8fb653a3023f6323e64"),
        ("unwinding", "0.2.10", "4b134ada16dda9e435abe2a6d76a01d497bc60707357845a15f9b0ed42dc88ce"),
        ("vex-sdk", "0.27.1", "79e5fe15afde1305478b35e2cb717fff59f485428534cf49cfdbfa4723379bf6"),
        ("wasip1", "1.0.0", "b5e26842486624357dbeb8f0381cf1fb42f022291fd787d4a816768fec8cc760"),
        ("wasip2", "1.0.4+wasi-0.2.12", "b67efb37e106e55ce722a510d6b5f9c17f083e5fc79afc2badeb12cc313d9487"),
        ("wasip3", "0.7.0+wasi-0.3.0", "07aa681120704bf09828d1f7cf7e763666c1dc6a36e5096efd0ad9aadfb302d3"),
        ("wit-bindgen", "0.57.1", "1ebf944e87a7c253233ad6766e082e3cd714b5d03812acc24c318f549614536e"),
    ),
}
CRATES_IO_DOWNLOAD = "https://static.crates.io/crates/{name}/{name}-{version}.crate"
MAX_CRATE_BYTES = 64 << 20
# The musl version Rust's self-contained libc.a must be (checked in its
# version.lo) for MUSL_COPYRIGHT to be the right file.
MUSL_VERSION = "1.2.5"
# musl's COPYRIGHT at v1.2.5 (git.musl-libc.org/cgit/musl/plain/COPYRIGHT?h=v1.2.5,
# sha256 f9bc4423732350eb0b3f7ed7e91d530298476f8fec0c6c427a1c04ade22655af).
MUSL_COPYRIGHT = """\
musl as a whole is licensed under the following standard MIT license:

----------------------------------------------------------------------
Copyright © 2005-2020 Rich Felker, et al.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
----------------------------------------------------------------------

Authors/contributors include:

A. Wilcox
Ada Worcester
Alex Dowad
Alex Suykov
Alexander Monakov
Andre McCurdy
Andrew Kelley
Anthony G. Basile
Aric Belsito
Arvid Picciani
Bartosz Brachaczek
Benjamin Peterson
Bobby Bingham
Boris Brezillon
Brent Cook
Chris Spiegel
Clément Vasseur
Daniel Micay
Daniel Sabogal
Daurnimator
David Carlier
David Edelsohn
Denys Vlasenko
Dmitry Ivanov
Dmitry V. Levin
Drew DeVault
Emil Renner Berthing
Fangrui Song
Felix Fietkau
Felix Janda
Gianluca Anzolin
Hauke Mehrtens
He X
Hiltjo Posthuma
Isaac Dunham
Jaydeep Patil
Jens Gustedt
Jeremy Huntwork
Jo-Philipp Wich
Joakim Sindholt
John Spencer
Julien Ramseier
Justin Cormack
Kaarle Ritvanen
Khem Raj
Kylie McClain
Leah Neukirchen
Luca Barbato
Luka Perkov
M Farkas-Dyck (Strake)
Mahesh Bodapati
Markus Wichmann
Masanori Ogino
Michael Clark
Michael Forney
Mikhail Kremnyov
Natanael Copa
Nicholas J. Kain
orc
Pascal Cuoq
Patrick Oppenlander
Petr Hosek
Petr Skocik
Pierre Carrier
Reini Urban
Rich Felker
Richard Pennington
Ryan Fairfax
Samuel Holland
Segev Finer
Shiz
sin
Solar Designer
Stefan Kristiansson
Stefan O'Rear
Szabolcs Nagy
Timo Teräs
Trutz Behn
Valentin Ochs
Will Dietz
William Haddon
William Pitcock

Portions of this software are derived from third-party works licensed
under terms compatible with the above MIT license:

The TRE regular expression implementation (src/regex/reg* and
src/regex/tre*) is Copyright © 2001-2008 Ville Laurikari and licensed
under a 2-clause BSD license (license text in the source files). The
included version has been heavily modified by Rich Felker in 2012, in
the interests of size, simplicity, and namespace cleanliness.

Much of the math library code (src/math/* and src/complex/*) is
Copyright © 1993,2004 Sun Microsystems or
Copyright © 2003-2011 David Schultz or
Copyright © 2003-2009 Steven G. Kargl or
Copyright © 2003-2009 Bruce D. Evans or
Copyright © 2008 Stephen L. Moshier or
Copyright © 2017-2018 Arm Limited
and labelled as such in comments in the individual source files. All
have been licensed under extremely permissive terms.

The ARM memcpy code (src/string/arm/memcpy.S) is Copyright © 2008
The Android Open Source Project and is licensed under a two-clause BSD
license. It was taken from Bionic libc, used on Android.

The AArch64 memcpy and memset code (src/string/aarch64/*) are
Copyright © 1999-2019, Arm Limited.

The implementation of DES for crypt (src/crypt/crypt_des.c) is
Copyright © 1994 David Burren. It is licensed under a BSD license.

The implementation of blowfish crypt (src/crypt/crypt_blowfish.c) was
originally written by Solar Designer and placed into the public
domain. The code also comes with a fallback permissive license for use
in jurisdictions that may not recognize the public domain.

The smoothsort implementation (src/stdlib/qsort.c) is Copyright © 2011
Valentin Ochs and is licensed under an MIT-style license.

The x86_64 port was written by Nicholas J. Kain and is licensed under
the standard MIT terms.

The mips and microblaze ports were originally written by Richard
Pennington for use in the ellcc project. The original code was adapted
by Rich Felker for build system and code conventions during upstream
integration. It is licensed under the standard MIT terms.

The mips64 port was contributed by Imagination Technologies and is
licensed under the standard MIT terms.

The powerpc port was also originally written by Richard Pennington,
and later supplemented and integrated by John Spencer. It is licensed
under the standard MIT terms.

All other files which have no copyright comments are original works
produced specifically for use as part of this library, written either
by Rich Felker, the main author of the library, or by one or more
contibutors listed above. Details on authorship of individual files
can be found in the git version control history of the project. The
omission of copyright and license comments in each file is in the
interest of source tree size.

In addition, permission is hereby granted for all public header files
(include/* and arch/*/bits/*) and crt files intended to be linked into
applications (crt/*, ldso/dlstart.c, and arch/*/crt_arch.h) to omit
the copyright notice and permission notice otherwise required by the
license, and to use these files without any requirement of
attribution. These files include substantial contributions from:

Bobby Bingham
John Spencer
Nicholas J. Kain
Rich Felker
Richard Pennington
Stefan Kristiansson
Szabolcs Nagy

all of whom have explicitly granted such permission.

This file previously contained text expressing a belief that most of
the files covered by the above exception were sufficiently trivial not
to be subject to copyright, resulting in confusion over whether it
negated the permissions granted in the license. In the spirit of
permissive licensing, and of not having licensing issues being an
obstacle to adoption, that text has been removed.
"""
# foamy-kit's LICENSE, for the vendored kit/rust crates (foamy-kit's tests
# keep it equal to the kit's LICENSE file).
KIT_LICENSE = """\
MIT License

Copyright (c) 2026 foamrider

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
# Standard license texts the toolchain does not ship (share/doc/rust/licenses
# has Apache-2.0, BSD-2-Clause, ISC, LLVM-exception, MIT, NCSA, Unicode-3.0, …),
# used only for a crate that ships no license file of its own.
EMBEDDED_LICENSES = {
    "MIT-0": """\
MIT No Attribution

Copyright <year> <copyright holders>

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
""",
}


def notice_name(parts):
    """A notice file's path parts: LICENSE*, COPYING*, … or any file in a
    LICENSES/ directory (REUSE layout), but no code or config file."""
    in_dir = len(parts) > 1 and parts[-2].lower() in ("licenses", "licences")
    return (bool(NOTICE_FILE_RE.fullmatch(parts[-1])) or in_dir) and not parts[-1].lower().endswith(NOT_NOTICE_SUFFIXES)


def normalize_text(data):
    """A notice's text: UTF-8 (invalid bytes replaced), no BOM, \\n line ends,
    no trailing spaces, no leading or trailing blank lines."""
    text = data.decode("utf-8", errors="replace") if isinstance(data, bytes) else data
    lines = [line.rstrip() for line in text.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def spdx_ids(expression):
    """The license ids in an SPDX expression (or a legacy "MIT/Apache-2.0")."""
    return sorted({token for token in re.split(r"[\s()/,]+", expression or "")
                   if token and token not in ("OR", "AND", "WITH", "or", "and")})


def split_name_version(text):
    match = NAME_VERSION_RE.fullmatch(text)
    return (match.group(1), match.group(2)) if match else None


def lock_packages(plugin):
    data = read_toml(Path(plugin) / "Cargo.lock")
    return {(p.get("name"), p.get("version")): p for p in data.get("package", []) if isinstance(p, dict)}


def linked_packages(plugin, crate, triple, env):
    """{(name, version): plugin-relative path or None for a registry crate}:
    the packages cargo compiles for `triple` into the crate's binary, with the
    features as built (the crate's defaults, the same resolver). Normal
    dependencies only: build-dependencies and proc-macro crates (and their
    own dependencies) run on the build host and are not linked."""
    plugin = Path(plugin)
    command = ["cargo", "tree", "--locked", "--target", triple, "--edges", "normal,no-proc-macro",
               "--prefix", "none", "--format", "{p}", "--color", "never",
               "--manifest-path", str(plugin / crate / "Cargo.toml"), "--config", str(plugin / RELEASE_PROFILE)]
    out = subprocess.run(command, env=env, cwd=plugin / crate, capture_output=True, text=True, timeout=600)
    if out.returncode != 0:
        raise KitError(f"cargo tree for {triple} failed (exit {out.returncode}; after `cargo fetch --locked` it "
                       f"works offline):\n{out.stderr.strip()[-2000:]}")
    found = {}
    top = plugin.resolve()
    for line in out.stdout.splitlines():
        line = line.strip().removesuffix(" (*)")
        if not line:
            continue
        match = TREE_LINE_RE.fullmatch(line)
        if not match:
            raise KitError(f"cargo tree printed an unexpected line: {line!r}")
        name, version, extra = match.groups()
        path = None
        if extra and extra.startswith("/"):
            resolved = Path(extra).resolve()
            if resolved != top and top not in resolved.parents:
                raise KitError(f"{name} {version} is a path dependency outside the plugin ({extra})")
            path = resolved.relative_to(top).as_posix()
        elif extra:
            raise KitError(f"{name} {version} comes from {extra}; only crates.io crates (locked by checksum) and "
                           "path dependencies inside the plugin are supported")
        found[(name, version)] = path
    return found


def manifest_license_file(manifest):
    """The crate-relative path of a manifest's `license-file`, or None."""
    package = manifest.get("package") if isinstance(manifest, dict) else None
    value = package.get("license-file") if isinstance(package, dict) else None
    if not isinstance(value, str) or not value.strip():
        return None
    import posixpath
    rel = posixpath.normpath(value.strip().replace("\\", "/")).removeprefix("./")
    return None if rel.startswith(("/", "../")) or rel in (".", "..") else rel


def crate_files(name, version, checksum, fetch=None):
    """[(path in the crate, bytes)]: the crate's Cargo.toml, its license
    files and its manifest's `license-file` whole, its source files' first
    4 KiB. Read only from the .crate archive in the cargo registry cache
    whose sha256 is the Cargo.lock checksum, never from an unpacked copy
    (nothing vouches for those bytes). A missing archive is fetched once
    through `fetch` (cargo fetch --locked), then it must be there."""
    registry = cargo_home() / "registry"
    archives = sorted((registry / "cache").glob(f"*/{name}-{version}.crate"))
    if not archives and fetch is not None:
        fetch()
        archives = sorted((registry / "cache").glob(f"*/{name}-{version}.crate"))
    if not archives:
        raise KitError(f"{name} {version}: no .crate archive in the cargo registry cache ({registry / 'cache'}); "
                       "run `cargo fetch --locked` in the plugin")
    archive = archives[0]
    data = archive.read_bytes()
    if sha256(data) != checksum:
        raise KitError(f"{archive} does not match the Cargo.lock checksum of {name} {version}; remove it and "
                       "run `cargo fetch --locked`")
    return read_crate(name, version, data, archive)


def read_crate(name, version, data, origin):
    """crate_files' list from the bytes of a verified .crate archive."""
    import io
    import tarfile
    prefix = f"{name}-{version}/"
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            members = {m.name[len(prefix):]: m for m in tar.getmembers()
                       if m.isfile() and m.name.startswith(prefix) and ".." not in m.name.split("/")}
            manifest = {}
            if "Cargo.toml" in members:
                try:
                    manifest = tomllib.loads(tar.extractfile(members["Cargo.toml"]).read().decode("utf-8", errors="replace"))
                except tomllib.TOMLDecodeError as error:
                    raise KitError(f"{name} {version}: Cargo.toml: {error}") from None
            license_file = manifest_license_file(manifest)
            if license_file is not None and license_file not in members:
                raise KitError(f"{name} {version}: its license-file {license_file!r} is not in the crate archive")
            files = []
            for rel, member in sorted(members.items()):
                whole = rel == "Cargo.toml" or rel == license_file or notice_name(rel.split("/"))
                if whole or rel.endswith(SOURCE_SUFFIXES):
                    stream = tar.extractfile(member)
                    files.append((rel, stream.read() if whole else stream.read(4096)))
    except (tarfile.TarError, OSError, EOFError) as error:
        raise KitError(f"{origin}: unreadable crate archive ({error})") from None
    return files


def download_crate(name, version):
    """The .crate from crates.io (verified by the caller)."""
    import urllib.request
    url = CRATES_IO_DOWNLOAD.format(name=name, version=version)
    request = urllib.request.Request(url, headers={"User-Agent": "foamy-kit-native-notices"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(MAX_CRATE_BYTES + 1)
    except OSError as error:
        raise KitError(f"downloading {url} failed ({error}); generate the notices with network access once, the "
                       f"archive is then cached") from None
    if len(data) > MAX_CRATE_BYTES:
        raise KitError(f"{url} is larger than {MAX_CRATE_BYTES} bytes")
    return data


def std_crate_files(name, version, checksum):
    """crate_files for a standard library dependency (cargo never fetches
    those): the .crate whose sha256 is the toolchain's library/Cargo.lock
    checksum, from cargo's registry cache, else the foamy-native cache, else
    downloaded from crates.io (unless CARGO_NET_OFFLINE) and cached there
    after it matched. An archive that doesn't match is refused."""
    cache = native_cache() / "crates" / f"{name}-{version}.crate"
    for path in sorted((cargo_home() / "registry/cache").glob(f"*/{name}-{version}.crate")) + [cache]:
        if path.is_file() and not path.is_symlink():
            data = path.read_bytes()
            if sha256(data) != checksum:
                raise KitError(f"{path} does not match the standard library's Cargo.lock checksum of {name} {version}; "
                               "remove it (it is downloaded again)")
            return read_crate(name, version, data, path)
    if os.environ.get("CARGO_NET_OFFLINE", "").lower() in ("1", "true", "yes"):
        raise KitError(f"{name} {version} (a standard library dependency) is not cached and CARGO_NET_OFFLINE is set; "
                       f"generate the notices with network access once (it is cached in {cache.parent})")
    data = download_crate(name, version)
    if sha256(data) != checksum:
        raise KitError(f"the {name} {version} archive from crates.io does not match the standard library's Cargo.lock "
                       f"checksum ({sha256(data)} vs {checksum}); refused")
    cache.parent.mkdir(parents=True, exist_ok=True)
    temp = cache.with_name(f".{cache.name}.{os.getpid()}")
    temp.write_bytes(data)
    os.replace(temp, cache)
    return read_crate(name, version, data, cache)


def std_lock(sysroot, channel):
    """{name: {version: checksum}}: the standard library's crates.io
    dependencies, from rust-src's library/Cargo.lock when installed (it must
    then agree with STD_LOCKS), else from STD_LOCKS."""
    embedded = None
    if channel in STD_LOCKS:
        embedded = {}
        for name, version, checksum in STD_LOCKS[channel]:
            embedded.setdefault(name, {})[version] = checksum
    path = Path(sysroot) / "lib/rustlib/src/rust/library/Cargo.lock"
    if path.is_file():
        found = {}
        for package in read_toml(path).get("package", []):
            if str(package.get("source", "")).startswith("registry+") and SHA_RE.fullmatch(str(package.get("checksum", ""))):
                found.setdefault(package["name"], {})[package["version"]] = package["checksum"]
        if embedded is not None and found != embedded:
            raise KitError(f"{path} disagrees with native.py's STD_LOCKS[{channel!r}]; regenerate that table")
        return found
    if embedded is None:
        raise KitError(f"no standard library Cargo.lock for Rust {channel}: install rust-src "
                       f"(rustup component add rust-src --toolchain {channel}) or add STD_LOCKS[{channel!r}] to native.py")
    return embedded


def crate_notices(label, files, licenses_dir, notice):
    """(SPDX expression, notice ids) of a crate from its verified files: the
    license files it ships, its source headers' copyright lines, and the
    standard texts of its licenses when it ships no license file at all."""
    manifest = {}
    for rel, data in files:
        if rel == "Cargo.toml":
            try:
                manifest = tomllib.loads(data.decode("utf-8", errors="replace"))
            except tomllib.TOMLDecodeError as error:
                raise KitError(f"{label}: Cargo.toml: {error}") from None
    spdx = str(manifest.get("package", {}).get("license", "") or "")
    shipped = license_files(files, manifest)
    ids = [notice(text, f"{label}: `{rel}`") for rel, text in shipped]
    copyrights, header_ids = header_notices(files)
    if copyrights:
        ids.append(notice("Copyright lines at the top of the crate's source files:\n\n" + "\n".join(copyrights),
                          f"{label}: source file headers"))
    if not shipped:
        for spdx_id in sorted(set(spdx_ids(spdx)) | set(header_ids)):
            text = standard_license(licenses_dir, spdx_id)
            if text is None:
                raise KitError(f"{label} ships no license file and native.py has no standard text for "
                               f"{spdx_id}; add it to EMBEDDED_LICENSES")
            ids.append(notice(text, f"{label}: standard {spdx_id} text (the crate ships no license file)"))
        if not spdx_ids(spdx):
            raise KitError(f"{label} has neither a license file nor a license in its Cargo.toml")
    return spdx, ids


def license_files(files, manifest):
    """[(path, text)] of the notice files a crate ships: LICENSE*, LICENCE*,
    COPYING*, NOTICE*, COPYRIGHT*, UNLICENSE and LICENSES/* anywhere outside
    tests, benches and examples (vendored code keeps its own: ring's
    third_party/fiat, …), and its Cargo.toml `license-file`."""
    license_file = manifest_license_file(manifest)
    found = {}
    for rel, data in files:
        parts = rel.split("/")
        included = len(parts) == 1 or parts[0] not in SOURCE_SKIP_DIRS
        notice = included and notice_name(parts)
        if notice or rel == license_file:
            text = normalize_text(data)
            if text:
                found[rel] = text
    return sorted(found.items())


def header_notices(files):
    """(copyright lines, SPDX ids) found in the first lines of the crate's
    source files outside tests, benches and examples: notices of code a
    crate includes from elsewhere (graviola's s2n-bignum, mlkem-native, …)."""
    lines, ids = set(), set()
    for rel, data in files:
        if not rel.endswith(SOURCE_SUFFIXES) or rel.split("/")[0] in SOURCE_SKIP_DIRS:
            continue
        for raw in data.decode("utf-8", errors="replace").splitlines()[:HEADER_LINES]:
            line = re.sub(r"^[\s/*#!;%\-]+|[\s*/]+$", "", raw).strip()
            spdx = SPDX_LINE_RE.search(line)
            if spdx:
                ids.update(spdx_ids(spdx.group(1)))
            elif COPYRIGHT_LINE_RE.match(line) and not NOT_COPYRIGHT_RE.match(line) and 8 < len(line) < 200:
                lines.add(line)
    return sorted(lines), sorted(ids)


def html_text(fragment):
    """Plain text of an HTML fragment (the toolchain's COPYRIGHT files)."""
    import html
    text = re.sub(r"<br\s*/?>|</p>|</h[1-6]>|</li>|</div>", "\n", fragment)
    text = html.unescape(re.sub(r"<[^>]+>", "", text))
    out = []
    for line in text.split("\n"):
        line = line.strip()
        if line or (out and out[-1]):
            out.append(line)
    return normalize_text("\n".join(out))


def toolchain_notices(sysroot):
    """From the pinned toolchain (the rustc component): the standard
    library's in-tree notices, its out-of-tree crates' notices
    {(name, version): (license, [(file, text)])}, the LLVM project entry of
    the compiler's notices, and the standard license texts directory."""
    import html
    doc = Path(sysroot) / "share/doc/rust"
    library = doc / "COPYRIGHT-library.html"
    compiler = doc / "COPYRIGHT.html"
    try:
        library_html = library.read_text(encoding="utf-8")
        compiler_html = compiler.read_text(encoding="utf-8")
    except OSError as error:
        raise KitError(f"the toolchain's notices are missing ({error}); reinstall the toolchain") from None
    start = library_html.find('<h2 id="longer-version">')
    middle = library_html.find('<h2 id="out-of-tree-dependencies">')
    if start < 0 or middle < start:
        raise KitError(f"{library}: unexpected layout (no in-tree / out-of-tree sections); update native.py")
    in_tree = html_text(library_html[start:middle])
    crates = {}
    for match in re.finditer(r"<h3>📦 ([^<]+)</h3>(.*?)(?=<h3>|</body>|\Z)", library_html[middle:], re.S):
        name_version = split_name_version(html.unescape(match.group(1)).strip())
        if not name_version:
            continue
        body = match.group(2)
        spdx = re.search(r"<b>License:</b>\s*([^<]*)</p>", body)
        notices = [(html.unescape(f).strip(), normalize_text(html.unescape(t)))
                   for f, t in re.findall(r"<summary><code>([^<]+)</code></summary>\s*<pre>(.*?)</pre>", body, re.S)]
        crates[name_version] = (html.unescape(spdx.group(1)).strip() if spdx else "", notices)
    llvm = re.search(r"<b>File/Directory:</b>\s*<code>src/llvm-project</code>(.*?)(?=<b>File/Directory:</b>|<h2)",
                     compiler_html, re.S)
    if not llvm:
        raise KitError(f"{compiler}: no src/llvm-project entry; update native.py")
    return {"in_tree": in_tree, "crates": crates,
            "llvm": "File/Directory: src/llvm-project\n" + html_text(llvm.group(1)), "licenses": doc / "licenses"}


def standard_license(licenses_dir, spdx):
    path = Path(licenses_dir) / f"{spdx}.txt"
    if spdx in EMBEDDED_LICENSES:
        return normalize_text(EMBEDDED_LICENSES[spdx])
    if re.fullmatch(r"[A-Za-z0-9.+-]+", spdx) and path.is_file():
        return normalize_text(path.read_bytes())
    return None


def ar_member(data, wanted):
    """The bytes of member `wanted` of a System V / GNU ar archive, or None."""
    if not data.startswith(b"!<arch>\n"):
        return None
    offset, names = 8, b""
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        name = header[:16].decode("ascii", errors="replace").rstrip()
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError:
            return None
        body = data[offset + 60:offset + 60 + size]
        if name == "//":
            names = body
        elif name.startswith("/") and name[1:].isdigit() and names:
            start = int(name[1:])
            name = names[start:names.find(b"\n", start)].decode("ascii", errors="replace")
        if name.rstrip("/") == wanted:
            return body
        offset += 60 + size + (size & 1)
    return None


def musl_version(sysroot, triple):
    libc = Path(sysroot) / "lib/rustlib" / triple / "lib/self-contained/libc.a"
    member = ar_member(libc.read_bytes(), "version.lo") if libc.is_file() else None
    match = re.search(rb"(?<![0-9.])(\d+\.\d+\.\d+)\x00", member or b"")
    return match.group(1).decode() if match else None


def sysroot_crates(sysroot, triple):
    lib = Path(sysroot) / "lib/rustlib" / triple / "lib"
    return sorted({m.group(1) for p in lib.glob("lib*.rlib") if (m := re.fullmatch(r"lib(.+)-[0-9a-f]+\.rlib", p.name))})


def elf_sources(data):
    """What the binary's embedded source paths (panic locations; the build
    remaps them to /cargo/…, /rustc/… and /rust/deps/…) show is linked:
    {"crates": {(name, version)}, "std_deps": {(name, version)}, "std": {crate}}."""
    def versions(regex):
        return {nv for m in regex.finditer(data) if (nv := split_name_version(m.group(1).decode()))}
    return {"crates": versions(ELF_CRATE_RE), "std_deps": versions(ELF_STD_DEP_RE),
            "std": {m.group(1).decode() for m in ELF_STD_RE.finditer(data)}}


def fence(text):
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def md_cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def notices_bytes(plugin, channel, binaries, env, cwd):
    """THIRD_PARTY_NOTICES.md for the plugin. `binaries`: [{"crate", "binary",
    "source", "files": {arch: bytes}}], one per pinned crate."""
    plugin = Path(plugin)
    sysroot_out = subprocess.run(["rustc", "--print", "sysroot"], env=env, cwd=cwd, capture_output=True, text=True,
                                 timeout=60)
    if sysroot_out.returncode != 0:
        raise KitError(f"rustc --print sysroot failed: {sysroot_out.stderr.strip()}")
    sysroot = Path(sysroot_out.stdout.strip())
    toolchain = toolchain_notices(sysroot)
    lock = lock_packages(plugin)
    pool, uses, order = {}, {}, []
    fetched = []

    def fetch():
        """cargo fetch --locked, once per generation (the build's environment)."""
        if fetched:
            return
        fetched.append(True)
        crate_dir = plugin / binaries[0]["crate"] if binaries else Path(cwd)
        result = subprocess.run(["cargo", "fetch", "--locked", "--manifest-path", str(crate_dir / "Cargo.toml")],
                                env=env, cwd=crate_dir, capture_output=True, text=True, timeout=600)
        if result.returncode != 0:
            raise KitError(f"cargo fetch --locked failed (exit {result.returncode}):\n{result.stderr.strip()[-2000:]}")

    def notice(text, label):
        text = normalize_text(text)
        if text not in pool:
            pool[text] = f"N{len(pool) + 1}"
            order.append(text)
        uses.setdefault(pool[text], [])
        if label not in uses[pool[text]]:
            uses[pool[text]].append(label)
        return pool[text]

    def refs(ids):
        return ", ".join(f"[{i}](#{i.lower()})" for i in dict.fromkeys(ids)) or "none"

    lines = [
        NOTICES_TITLE,
        "",
        "Generated by `kit/native/build-native.sh` (foamy-kit) with the binaries; do not edit. "
        "`kit/native/build-native.sh .` rewrites it, `kit/native/build-native.sh . --verify` (and the "
        "Verify native helpers workflow) fails when it differs from a fresh generation, and "
        "`tests/kit-check.sh` fails when it is missing or names other binaries than `native.pin`.",
        "",
        "The helper binaries below are static executables. Besides this plugin's own code (see `LICENSE`) "
        "and foamy-kit's shared crate, they contain the third-party code listed for each, and this file "
        "reproduces the license texts and copyright notices that code ships (under [Notices](#notices)). "
        "Where a component offers a choice of licenses, every text it ships is reproduced. This is a "
        "supply-chain record, not a legal determination.",
        "",
        "How the lists are made:",
        "",
        "- **Crates**: `cargo tree --locked --target <triple> --edges normal,no-proc-macro` for each musl "
        "target, with the features the build uses. Build-dependencies and proc-macro crates (with their "
        "own dependencies) run on the build host and are not linked. `Cargo.lock` also lists crates for "
        "other platforms (windows-*, …) and for features this build does not enable (ring, aws-lc, …): "
        "those are not compiled and not listed. A crate whose code link-time optimization drops entirely "
        "is still listed. Every crate source path embedded in the binaries (panic locations) is checked "
        "to be in the list when the file is generated.",
        "- **Crate notices**: read from the crate archive (`.crate`) whose SHA-256 is the `Cargo.lock` "
        "checksum shown: its `LICENSE*`, `LICENCE*`, `COPYING*`, `NOTICE*`, `COPYRIGHT*` and `UNLICENSE` "
        "files and `license-file`, plus the copyright lines and SPDX ids at the top of its source files "
        "(outside tests, benches and examples). For a crate that ships no license file, the standard text "
        "of each license its SPDX expression names is reproduced instead, and marked so.",
        "- **Toolchain**: the Rust standard library (in-tree notices from the pinned toolchain's "
        "`share/doc/rust/COPYRIGHT-library.html`) and its crates.io dependencies at the versions of the "
        "toolchain's `library/Cargo.lock` (the notice file's entry for that version, else the `.crate` archive with the lock's "
        "checksum), musl libc and the C runtime objects of Rust's "
        "self-contained musl linking, and LLVM's libunwind and crtbegin/crtend (from the toolchain's "
        "`COPYRIGHT.html`).",
        "",
    ]
    std_names = None
    detected_std_deps = set()
    sections = []
    for entry in sorted(binaries, key=lambda e: e["binary"]):
        crate, binary = entry["crate"], entry["binary"]
        linked = {}
        for arch, triple in ARCHES.items():
            packages = linked_packages(plugin, crate, triple, env)
            data = entry["files"].get(arch)
            # Another crate's binary that its sources have outgrown (a shared
            # dependency was updated) shows the old graph; it is rebuilt next,
            # and until then kit-check and --verify report it stale.
            if data is not None and not entry.get("stale"):
                seen = elf_sources(data)
                missing = sorted(nv for nv in seen["crates"] if nv not in packages)
                if missing:
                    raise KitError(f"bin/{arch}/{binary} contains code of " + ", ".join(f"{n} {v}" for n, v in missing)
                                   + ", which cargo tree does not list; the notices would be incomplete")
                detected_std_deps |= seen["std_deps"]
            for key, path in packages.items():
                linked.setdefault(key, {"path": path, "arches": []})["arches"].append(arch)
        if std_names is None:
            std_names = {arch: set(sysroot_crates(sysroot, triple)) for arch, triple in ARCHES.items()}
        sections.append((entry, linked))

    for entry, linked in sections:
        crate, binary = entry["crate"], entry["binary"]
        lines += [f"## `{binary}`", ""]
        for arch in sorted(entry["files"]):
            lines.append(f"- `bin/{arch}/{binary}`: sha256 `{sha256(entry['files'][arch])}`")
        lines += [f"- `{crate}/{PIN_NAME}`: source `{entry['source']}`, toolchain {channel}", ""]
        first, third = [], []
        for (name, version), info in sorted(linked.items()):
            arches = "both" if len(info["arches"]) == len(ARCHES) else ", ".join(info["arches"])
            if info["path"] is not None:
                manifest = read_toml(plugin / info["path"] / "Cargo.toml")
                spdx = manifest.get("package", {}).get("license", "")
                if info["path"].startswith("kit/rust/"):
                    ids = [notice(KIT_LICENSE, f"{name} {version} (foamy-kit's LICENSE)")]
                    owner = "foamy-kit, vendored"
                else:
                    ids, owner = [], "this plugin"
                first.append(f"| {md_cell(name)} | {md_cell(version)} | `{info['path']}/` ({owner}) | "
                             f"{md_cell(spdx)} | {arches} | {refs(ids) if ids else '`LICENSE`'} |")
                continue
            package = lock.get((name, version), {})
            checksum = package.get("checksum", "")
            if not str(package.get("source", "")).startswith("registry+") or not SHA_RE.fullmatch(checksum):
                raise KitError(f"{name} {version}: Cargo.lock records no crates.io source and checksum")
            files = crate_files(name, version, checksum, fetch)
            spdx, ids = crate_notices(f"{name} {version}", files, toolchain["licenses"], notice)
            third.append(f"| {md_cell(name)} | {md_cell(version)} | {md_cell(spdx)} | `{checksum}` | {arches} | "
                         f"{refs(ids)} |")
        lines += [f"### Crates linked into `{binary}`", "",
                  "| Crate | Version | License (Cargo.toml) | Cargo.lock checksum (sha256 of the .crate) | Arches | Notices |",
                  "|---|---|---|---|---|---|", *third, "",
                  "First-party crates (not third-party code, listed for completeness):", "",
                  "| Crate | Version | Source | License | Arches | Notices |", "|---|---|---|---|---|---|", *first, ""]
        sections_std = toolchain_rows(entry, toolchain, std_names, detected_std_deps, channel, sysroot, notice, refs,
                                      std_lock(sysroot, channel))
        lines += [f"### Toolchain code linked into `{binary}`", "", *sections_std, ""]

    lines += ["## Notices", ""]
    for index, text in enumerate(order, 1):
        ident = f"N{index}"
        quote = fence(text)
        lines += [f"### {ident}", "", "Shipped by: " + "; ".join(uses[ident]) + ".", "", f"{quote}text", text, quote, ""]
    return ("\n".join(lines).rstrip("\n") + "\n").encode()


def toolchain_rows(entry, toolchain, std_names, detected_std_deps, channel, sysroot, notice, refs, std_deps):
    """The standard library, musl and LLVM rows of one binary's section."""
    rows = ["| Component | Version | License | Arches | Notices |", "|---|---|---|---|---|"]
    names = set().union(*std_names.values())
    in_tree = sorted(n for n in names if n in SYSROOT_IN_TREE and n not in SYSROOT_NOT_LINKED)
    in_tree_ids = [notice(toolchain["in_tree"], f"Rust {channel} standard library: COPYRIGHT-library.html (in-tree files)")]
    for spdx_id in sorted({i for m in re.finditer(r"^License: (.+)$", toolchain["in_tree"], re.M) for i in spdx_ids(m.group(1))}):
        text = standard_license(toolchain["licenses"], spdx_id)
        if text:
            in_tree_ids.append(notice(text, f"Rust {channel}: standard {spdx_id} text (share/doc/rust/licenses)"))
    rows.append(f"| Rust standard library ({', '.join(f'`{n}`' for n in in_tree)}) | {channel} | "
                f"Apache-2.0 OR MIT (exceptions in the notice) | both | {refs(in_tree_ids)} |")
    def key(name):
        return name.replace("-", "_")

    covered = set()
    for name in sorted(names - SYSROOT_IN_TREE - set(SYSROOT_NOT_LINKED)):
        locked = {(n, v): c for n, versions in std_deps.items() if key(n) == key(name) for v, c in versions.items()}
        if not locked:
            raise KitError(f"the sysroot crate {name} is neither in the Rust repository nor in the standard library's "
                           "Cargo.lock, so its notices can't be obtained")
        found = sorted(v for n, v in detected_std_deps if key(n) == key(name))
        arches = "both" if all(name in s for s in std_names.values()) else ", ".join(a for a, s in sorted(std_names.items()) if name in s)
        chosen = {nv: c for nv, c in locked.items() if nv[1] in found} if found else locked
        if found and len(chosen) != len(set(found)):
            raise KitError(f"the binaries contain {name} {', '.join(found)}, the standard library's Cargo.lock has "
                           f"{', '.join(v for _, v in sorted(locked))}")
        for (crate_name, version), checksum in sorted(chosen.items()):
            covered.add((key(crate_name), version))
            label = f"Rust {channel} standard library dependency {crate_name} {version}"
            listed = toolchain["crates"].get((crate_name, version))
            if listed:
                spdx, files = listed
                ids = [notice(text, f"{label}: `{f}`") for f, text in files]
                source = ""
            else:
                spdx, ids = crate_notices(label, std_crate_files(crate_name, version, checksum), toolchain["licenses"], notice)
                source = f"; notices from the crates.io archive, sha256 `{checksum}`"
            if not ids:
                raise KitError(f"{label}: no notice text")
            note = "" if found else "; the version (from the toolchain's library/Cargo.lock) is not visible in the binaries"
            rows.append(f"| `{crate_name}` (a dependency of the standard library{note}{source}) | {version} | "
                        f"{md_cell(spdx)} | {arches} | {refs(ids)} |")
    unknown = sorted(f"{n} {v}" for n, v in detected_std_deps if (key(n), v) not in covered)
    if unknown:
        raise KitError("the binaries contain standard library dependencies without notices: " + ", ".join(unknown))
    musl = {arch: musl_version(sysroot, triple) for arch, triple in ARCHES.items()}
    if any(version != MUSL_VERSION for version in musl.values()):
        raise KitError(f"the toolchain's self-contained musl is {musl}, native.py has the COPYRIGHT of musl "
                       f"{MUSL_VERSION}; update MUSL_VERSION and MUSL_COPYRIGHT")
    musl_id = notice(MUSL_COPYRIGHT, f"musl libc {MUSL_VERSION}: `COPYRIGHT`")
    rows.append(f"| musl libc (`libc.a`) and its C runtime objects (`crt1.o`, `rcrt1.o`, `Scrt1.o`, `crti.o`, `crtn.o`), "
                f"from Rust's self-contained musl | {MUSL_VERSION} | MIT | both | {refs([musl_id])} |")
    llvm_ids = [notice(toolchain["llvm"], f"Rust {channel}: COPYRIGHT.html (src/llvm-project)")]
    for spdx_id in ("Apache-2.0", "LLVM-exception", "NCSA"):
        text = standard_license(toolchain["licenses"], spdx_id)
        if text:
            llvm_ids.append(notice(text, f"Rust {channel}: standard {spdx_id} text (share/doc/rust/licenses)"))
    rows.append(f"| LLVM libunwind (`libunwind.a`) and compiler-rt `crtbegin.o`/`crtend.o`, from Rust's self-contained "
                f"musl | as shipped with Rust {channel} | Apache-2.0 WITH LLVM-exception AND NCSA | both | {refs(llvm_ids)} |")
    rows.append("")
    rows.append("Not linked (sysroot crates a release helper does not use): "
                + "; ".join(f"`{n}`: {why}" for n, why in sorted(SYSROOT_NOT_LINKED.items())
                            if any(n in s for s in std_names.values())) + ".")
    return rows


def notices_problems(plugin, pins):
    """Without cargo: the notices file exists and names each pin's source hash
    and binary checksums (as tests/kit-check.sh checks it)."""
    path = Path(plugin) / NOTICES_NAME
    if not pins:
        return []
    if path.is_symlink() or not path.is_file():
        return [f"{NOTICES_NAME} is missing (run kit/native/build-native.sh .)"]
    text = path.read_text(errors="replace")
    lines = set(text.splitlines())
    problems = []
    if not text.startswith(NOTICES_TITLE + "\n"):
        problems.append(f"{NOTICES_NAME} was not written by kit/native/build-native.sh")
    for pin_path in pins:
        crate = pin_path.parent.name
        pin = read_pin(pin_path)
        wanted = [f"- `{crate}/{PIN_NAME}`: source `{pin.get('source')}`, toolchain {pin.get('toolchain')}"]
        wanted += [f"- `{rel}`: sha256 `{sha}`" for rel, sha in sorted(pin["files"].items())]
        if any(line not in lines for line in wanted):
            problems.append(f"{NOTICES_NAME} does not match {crate}/{PIN_NAME} (run kit/native/build-native.sh .)")
    return problems


def notice_entries(plugin, current=None):
    """notices_bytes' binaries: every pinned crate with its committed
    binaries, `current` ({"crate", "binary", "source", "files"}) in place of
    its crate's. A committed binary whose pin no longer matches its sources
    is marked "stale": its embedded paths are not checked against the new
    dependency graph, so crates sharing an updated dependency can be rebuilt
    one after another."""
    plugin = Path(plugin)
    entries = [current] if current else []
    for pin_path in native_pins(plugin):
        crate = pin_path.parent.name
        if current and crate == current["crate"]:
            continue
        pin = read_pin(pin_path)
        binary = pin.get("binary", "")
        if not NAME_RE.fullmatch(binary):
            raise KitError(f"{crate}/{PIN_NAME} has no valid binary name")
        files = {arch: (plugin / f"bin/{arch}/{binary}").read_bytes() for arch in ARCHES
                 if (plugin / f"bin/{arch}/{binary}").is_file() and not (plugin / f"bin/{arch}/{binary}").is_symlink()}
        entries.append({"crate": crate, "binary": binary, "source": pin.get("source"), "files": files,
                        "stale": native_source_hash(plugin, crate) != pin.get("source")})
    return entries


def notices_env(plugin, crate, channel, target_dir):
    """cargo tree's environment: the build's, so target cfgs resolve alike."""
    return cargo_env(target_dir, channel, build_flags(plugin, crate, target_dir), ARCHES.values())


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
        if getattr(args, "notices", False):
            if not (crate_dir / PIN_NAME).is_file():
                raise KitError(f"no {crate}/{PIN_NAME}; build first (kit/native/build-native.sh .)")
            stale = [p for p in verify_native(plugin, read_lock(plugin)) if not p.startswith(NOTICES_NAME)]
            if stale:
                raise KitError("the committed binaries don't match their native.pin and sources; rebuild them "
                               "(kit/native/build-native.sh .), which writes the notices too:\n  " + "\n  ".join(stale))
            env = notices_env(plugin, crate, channel, target_dir)
            check_toolchain(env, channel, crate_dir)
            data = notices_bytes(plugin, channel, notice_entries(plugin), env, crate_dir)
            changed = install_atomic(plugin, NOTICES_NAME, data, 0o644)
            print(f"{plugin.name}: {NOTICES_NAME} " + ("updated" if changed else "up to date"))
            return 0
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
            current = {"crate": crate, "binary": binary, "source": source, "files": built}
            notices = notices_bytes(plugin, channel, notice_entries(plugin, current),
                                    notices_env(plugin, crate, channel, cache), crate_dir)
            notices_path = plugin / NOTICES_NAME
            committed_notices = (notices_path.read_bytes() if notices_path.is_file() and not notices_path.is_symlink()
                                 else b"")
            if notices != committed_notices:
                problems.append(f"{NOTICES_NAME}: a fresh generation differs from the committed file "
                                f"(run kit/native/build-native.sh . and commit it)")
            else:
                print(f"{NOTICES_NAME}: identical to a fresh generation ({len(notices)} bytes)")
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
        current = {"crate": crate, "binary": binary, "source": source, "files": built}
        notices = notices_bytes(plugin, channel, notice_entries(plugin, current),
                                notices_env(plugin, crate, channel, target_dir), crate_dir)
        changed = [f"bin/{arch}/{binary}" for arch, data in sorted(built.items())
                   if install_atomic(plugin, f"bin/{arch}/{binary}", data, 0o755)]
        if install_atomic(plugin, f"{crate}/{PIN_NAME}", pin_bytes(crate, binary, channel, source, built, read_lock(plugin)["version"]), 0o644):
            changed.append(f"{crate}/{PIN_NAME}")
        if install_atomic(plugin, NOTICES_NAME, notices, 0o644):
            changed.append(NOTICES_NAME)
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
                    f"and write <crate>/native.pin and {NOTICES_NAME}; or verify or test them.")
    parser.add_argument("plugin", help="the plugin directory (. from its root)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--verify", action="store_true",
                      help="rebuild in a fresh target dir and compare with the committed binaries")
    mode.add_argument("--test", action="store_true", help="cargo fmt --check, clippy -D warnings and test for the crate")
    mode.add_argument("--notices", action="store_true",
                      help=f"only rewrite {NOTICES_NAME} (for current binaries; the build and --verify include it)")
    parser.add_argument("--out", metavar="DIR", help="with --verify: also write the rebuilt binaries to DIR/<arch>/<binary>")
    parser.add_argument("--crate", help="crate directory (default: the one with a native.pin, else native)")
    parser.add_argument("--bin", help="binary name (default: native.pin's, else foamy-<plugin>-helper)")
    return cmd_native(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
