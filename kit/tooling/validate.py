#!/usr/bin/env python3
# foamy-kit 0.9.0 d5377f7e0337828bc9950e0e651403e128e8216bb4673b2ec173fde63f24be1b — do not edit; change foamy-kit and run sync
"""The one validation command of foamy-kit and every Foamy plugin.

Run it as `tests/validate.sh` (sync.sh writes that wrapper and this file into
every plugin; foamy-kit runs the same files on itself):

  tests/validate.sh                    # everything, on the Omarchy host
  tests/validate.sh --ci               # no Quickshell runtime, no host (GitHub CI)
  tests/validate.sh --fast             # skip the native helper tests; the suite gets --fast
  tests/validate.sh --only ruff,oxlint # or --skip CHECKS
  tests/validate.sh --update-baseline [CHECKS]   # rewrite lint baselines, then review the diff
  tests/validate.sh --list             # the checks and what each runs

It exits nonzero when any check fails. A missing or wrongly versioned tool is
a failure that says to run `mise install`, never a pass. Checks that cannot
run where you are (the host tools under --ci) are reported as SKIP with the
reason.

Tools: the versions in mise.toml (kit-owned), found with `mise which` (or on
PATH without mise) and version-checked. Configuration: ruff.toml,
.oxlintrc.json and .qmlformat.ini (kit-owned) plus the shfmt and qmllint
flags below. Repository-owned additions, never synced, all optional:

  .ruff.toml                    extends the kit's ruff.toml (`extend = "ruff.toml"`)
  tests/lint/oxlintrc.json      extends the kit's config (`"extends": ["../../.oxlintrc.json"]`)
  tests/lint/exclude.txt        `<glob> [checks]  # reason`: paths no check (or only the
                                named checks) reads, such as test inputs
  tests/lint/vulture-ignore.txt `<name>  # reason`: dynamic entry points Vulture can't see
  tests/lint/<check>-baseline.txt   reviewed findings at adoption (qmllint, oxlint,
                                    ruff, vulture, shellcheck); only new ones fail
  tests/suite.sh                the repository's own tests, run last with the
                                same --ci / --fast flags

In a plugin, every file foamy-kit.lock lists and everything under kit/ is
kit-owned: no check here reformats or lints it (foamy-kit checks its own).
Standard library only; Python 3.11 or newer.
"""

import argparse
import collections
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK_NAME = "foamy-kit.lock"
LINT_DIR = "tests/lint"
SUITE = "tests/suite.sh"
QT_BIN = Path(os.environ.get("FOAMY_QT_BIN", "/usr/lib/qt6/bin"))
DEFAULT_KIT = Path.home() / "GitHub/Personal/foamy-kit"
# shfmt: 2-space indent, indented `case` arms, `&&`/`||` starting the
# continuation line (the smallest change to the existing kit and plugin scripts).
SHFMT_FLAGS = ["-i", "2", "-ci", "-bn"]
# qmllint: every default category, plus unused imports as errors. Qt Design
# Studio's categories don't apply (no .ui.qml files). --ignore-settings keeps
# a stray .qmllint.ini from changing what this command checks.
QMLLINT_FLAGS = ["--ignore-settings", "--unused-imports", "error"] + [
    item
    for name in (
        "FunctionsNotSupportedInQmlUi",
        "ImperativeCodeNotEditableInVisualDesigner",
        "InvalidIdeInVisualDesigner",
        "ReferenceToParentItemNotSupportedByVisualDesigner",
        "TranslationFunctionMismatch",
        "UnsupportedRootTypeInQmlUi",
        "UnsupportedTypeInQmlUi",
    )
    for item in (f"--QtDesignStudio.{name}", "disable")
]
VULTURE_CONFIDENCE = "60"  # every Vulture finding: unused functions, classes, attributes and imports
# Tools in mise.toml: key -> the executable it provides.
BINARIES = {
    "node": "node",
    "aqua:astral-sh/ruff": "ruff",
    "aqua:oxc-project/oxc/oxlint": "oxlint",
    "pipx:vulture": "vulture",
    "aqua:mvdan/sh": "shfmt",
    "aqua:koalaman/shellcheck": "shellcheck",
}
SKIP_DIRS = {".git", "node_modules", "target", "__pycache__"}
SHELL_SHEBANG = re.compile(r"^#!\s*\S*/(?:env\s+)?(?:bash|sh|dash)\b")


class Failure(Exception):
    """A check that could not run (missing tool, bad configuration)."""


class Skip(Exception):
    """A check that does not apply here, with the reason."""


# ------------------------------------------------------------------ the repo


class Repo:
    def __init__(self, root, args):
        self.root = Path(root)
        self.args = args
        self.kit_mode = (self.root / "kit/components.json").is_file() and not (self.root / "manifest.json").is_file()
        self.kit_owned = self._kit_owned()
        self.excludes = read_reasoned(self.root / LINT_DIR / "exclude.txt", "path pattern")
        known = {name for name, _, _ in CHECKS}
        for entry, _ in self.excludes:
            unknown = [c for c in entry.split()[1:] if c not in known]
            if unknown:
                raise Failure(f"{LINT_DIR}/exclude.txt: {entry}: unknown check(s) {', '.join(unknown)}")
        self.files = self._files()
        self._tools = {}
        self._env = None
        self.pins = self._pins()

    def _kit_owned(self):
        if self.kit_mode:
            return set()
        lock = self.root / LOCK_NAME
        owned = set()
        if lock.is_file():
            for line in lock.read_text().splitlines():
                parts = line.split()
                if len(parts) == 2 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
                    owned.add(parts[1])
        return owned

    def is_kit_owned(self, rel):
        return not self.kit_mode and (rel.startswith("kit/") or rel in self.kit_owned)

    def _files(self):
        try:
            out = subprocess.run(
                ["git", "-C", str(self.root), "ls-files", "-z", "-co", "--exclude-standard"],
                capture_output=True,
                timeout=60,
                check=True,
            ).stdout
            names = sorted({n for n in out.decode().split("\0") if n})
        except (OSError, subprocess.SubprocessError):
            names = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*") if p.is_file())
        keep = []
        for rel in names:
            path = self.root / rel
            if SKIP_DIRS & set(Path(rel).parts) or path.is_symlink() or not path.is_file():
                continue
            if self.is_kit_owned(rel) or self.excluded(rel, None):
                continue
            keep.append(rel)
        return keep

    def excluded(self, rel, check):
        """Whether tests/lint/exclude.txt keeps `rel` from `check` (None: from all)."""
        for entry, _ in self.excludes:
            pattern, *checks = entry.split()
            if (not checks or (check is not None and check in checks)) and fnmatch.fnmatch(rel, pattern):
                return True
        return False

    def by_suffix(self, check, *suffixes):
        return [f for f in self.files if f.endswith(suffixes) and not self.excluded(f, check)]

    def shell_files(self, check):
        out = []
        for rel in self.files:
            if self.excluded(rel, check):
                continue
            if rel.endswith((".sh", ".sh.in")):
                out.append(rel)
            elif "." not in Path(rel).name or rel.endswith(".bash"):
                try:
                    with open(self.root / rel, "rb") as handle:
                        first = handle.readline(200).decode("utf-8", "replace")
                except OSError:
                    continue
                if SHELL_SHEBANG.match(first):
                    out.append(rel)
        return out

    def _pins(self):
        import tomllib

        path = self.root / "mise.toml"
        if not path.is_file():
            raise Failure("mise.toml is missing (foamy-kit sync.sh writes it)")
        tools = tomllib.loads(path.read_text()).get("tools", {})
        return {BINARIES[key]: str(version) for key, version in tools.items() if key in BINARIES}

    def tool(self, name):
        """Absolute path of a pinned tool, version-checked."""
        if name in self._tools:
            return self._tools[name]
        version = self.pins.get(name)
        if version is None:
            raise Failure(f"mise.toml pins no {name}")
        path = None
        if shutil.which("mise"):
            result = subprocess.run(["mise", "which", name], cwd=self.root, capture_output=True, text=True, timeout=60)
            if result.returncode == 0 and result.stdout.strip():
                path = result.stdout.strip().splitlines()[-1]
        path = path or shutil.which(name)
        if not path:
            raise Failure(f"{name} {version} is not installed; run `mise install` here (https://mise.jdx.dev)")
        result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=60)
        found = (result.stdout + result.stderr).strip()
        if not re.search(rf"(?<![\d.]){re.escape(version)}(?![\d.])", found):
            raise Failure(
                f"{path} is {found.splitlines()[0] if found else 'unknown'}, mise.toml pins {name} {version}; "
                "run `mise install` here"
            )
        self._tools[name] = path
        return path

    def env(self):
        """The environment for checks and the suite: pinned tools first on PATH."""
        if self._env is not None:
            return self._env
        env = dict(os.environ)
        dirs = []
        for name in self.pins:
            try:
                dirs.append(str(Path(self.tool(name)).parent))
            except Failure:
                pass
        env["PATH"] = os.pathsep.join(dict.fromkeys(dirs + env.get("PATH", "").split(os.pathsep)))
        kit = foamy_kit(self)
        if kit and "FOAMY_KIT" not in env:
            env["FOAMY_KIT"] = str(kit)
        env["FOAMY_VALIDATE"] = "ci" if self.args.ci else "fast" if self.args.fast else "full"
        self._env = env
        return env


def read_reasoned(path, what):
    """[(entry, reason)] from a `<entry>  # reason` file; a missing reason fails."""
    if not path.is_file():
        return []
    entries = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        entry, _, reason = line.partition("#")
        if not entry.strip() or not reason.strip():
            raise Failure(f"{path.name}:{number}: each {what} needs a reason: `<{what}>  # why`")
        entries.append((entry.strip(), reason.strip()))
    return entries


def foamy_kit(repo):
    """The foamy-kit checkout for check.sh and the runtime tests' harness:
    FOAMY_KIT, else ~/GitHub/Personal/foamy-kit or a sibling foamy-kit (not
    under --ci: on the runner, only the kit checks.yml checks out counts)."""
    if repo.kit_mode:
        return repo.root
    defaults = () if repo.args.ci else (DEFAULT_KIT, repo.root.parent / "foamy-kit")
    for candidate in (os.environ.get("FOAMY_KIT"), *defaults):
        if (
            candidate
            and (Path(candidate) / "check.sh").is_file()
            and (Path(candidate) / "kit/components.json").is_file()
        ):
            return Path(candidate).resolve()
    return None


def run(cmd, repo, **kwargs):
    kwargs.setdefault("timeout", 900)
    return subprocess.run(cmd, cwd=repo.root, env=repo.env(), capture_output=True, text=True, **kwargs)


def show(text, limit=200):
    lines = text.rstrip().splitlines()
    for line in lines[:limit]:
        print(f"    {line}")
    if len(lines) > limit:
        print(f"    … {len(lines) - limit} more lines")


# --------------------------------------------------------------- baselines

MEASURE = re.compile(r"\((\d+) > (\d+)\)")


def finding(path, rule, message, repo, line=None, base=None):
    """A baseline entry: stable across line shifts (path, rule, message and the
    reported source line's text, not its number). Paths in the message are
    made relative to the repository (`base`: where the tool ran)."""
    message = " ".join(str(message).split("\n")[0].split())
    for prefix in (base, repo.root):
        if prefix:
            message = message.replace(f"{prefix}/", "").replace(str(prefix), ".")
    code = ""
    if line:
        try:
            code = (repo.root / path).read_text(errors="replace").splitlines()[int(line) - 1]
        except (OSError, IndexError, ValueError):
            code = ""
    code = " ".join(code.split())[:160]
    return f"{path}: {rule}: {message}" + (f" | {code}" if code else "")


def split_measure(entry):
    """("… too complex (> 15) …", 51) for a C901-style entry, else (entry, None)."""
    match = MEASURE.search(entry.split(" | ")[0])
    if not match:
        return entry, None
    return entry[: match.start()] + f"(> {match.group(2)})" + entry[match.end() :], int(match.group(1))


def compare(check, entries, repo):
    """Fail on findings not in tests/lint/<check>-baseline.txt (a measured
    finding also fails when its measure grew); --update-baseline rewrites it."""
    path = repo.root / LINT_DIR / f"{check}-baseline.txt"
    current = collections.Counter()
    measures = {}
    for entry in entries:
        key, value = split_measure(entry)
        current[key] += 1
        if value is not None:
            measures[key] = max(measures.get(key, 0), value)
    if repo.args.update_baseline is not None and check in repo.update:
        old = baseline(path)[0]
        lines = [
            f"# {check} findings accepted when the check was adopted. tests/validate.sh fails on any",
            "# finding not listed here. Regenerate with `tests/validate.sh --update-baseline " + check + "`",
            "# only to drop fixed entries or after reviewing every added one; never to pass a check.",
        ]
        for key in sorted(current.elements()):
            lines.append(key if key not in measures else f"{key} [{measures[key]}]")
        path.parent.mkdir(parents=True, exist_ok=True)
        if current:
            path.write_text("\n".join(lines) + "\n")
        elif path.exists():
            path.unlink()
        added, removed = sum((current - old).values()), sum((old - current).values())
        print(
            f"    wrote {path.relative_to(repo.root)}: {sum(current.values())} entries ({added} added, {removed} removed)"
            if current
            else f"    no findings; {path.relative_to(repo.root)} removed"
            if old
            else "    no findings"
        )
        return
    old, old_measures = baseline(path)
    new = current - old
    grew = [
        f"{key} (now {measures[key]}, baseline {old_measures[key]})"
        for key in measures
        if key in old and key in old_measures and measures[key] > old_measures[key]
    ]
    fixed = sum((old - current).values())
    known = sum(current.values()) - sum(new.values())
    if known:
        print(f"    {known} baselined finding(s) in {path.relative_to(repo.root)}")
    if fixed:
        print(
            f"    {fixed} baseline entr{'y is' if fixed == 1 else 'ies are'} fixed; shrink the baseline: "
            f"tests/validate.sh --update-baseline {check}"
        )
    problems = [f"new: {key}" for key in sorted(new.elements())] + [f"grew: {key}" for key in grew]
    if problems:
        show("\n".join(problems))
        raise Failure(f"{len(problems)} new finding(s)")


def baseline(path):
    counter, measures = collections.Counter(), {}
    if path.is_file():
        for line in path.read_text().splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            match = re.search(r" \[(\d+)\]$", line)
            key = line[: match.start()] if match else line
            counter[key] += 1
            if match:
                measures[key] = int(match.group(1))
    return counter, measures


# ------------------------------------------------------------------ checks


def check_kit(repo):
    if repo.kit_mode:
        raise Skip("foamy-kit itself (tests/test_sync_check.py covers kit-check.sh)")
    result = run(["bash", "tests/kit-check.sh"], repo)
    show(result.stdout + result.stderr)
    if result.returncode != 0:
        raise Failure("tests/kit-check.sh failed")


def check_plugin_validate(repo):
    if repo.kit_mode:
        raise Skip("foamy-kit is not a plugin")
    if repo.args.ci:
        raise Skip("--ci: omarchy-plugin-validate is part of the Omarchy host")
    validator = shutil.which("omarchy-plugin-validate") or "/usr/share/omarchy/bin/omarchy-plugin-validate"
    if not os.access(validator, os.X_OK):
        raise Failure("omarchy-plugin-validate not found (an Omarchy host tool; use --ci elsewhere)")
    result = run([validator, str(repo.root)], repo, timeout=120)
    show(result.stdout + result.stderr)
    if result.returncode != 0:
        raise Failure("omarchy-plugin-validate failed")


def check_design_lint(repo):
    if repo.kit_mode:
        raise Skip("foamy-kit's own design lint runs in tests/test_sync_check.py")
    kit = foamy_kit(repo)
    if kit is None:
        configured = os.environ.get("FOAMY_KIT")
        if configured:
            raise Failure(f"FOAMY_KIT={configured} is not a foamy-kit checkout (no check.sh and kit/components.json)")
        if repo.args.ci:
            raise Skip("--ci: FOAMY_KIT is unset (checks.yml sets it to the kit commit foamy-kit.lock names)")
        raise Skip("no foamy-kit checkout: set FOAMY_KIT, or keep it at ~/GitHub/Personal/foamy-kit")
    result = run(["bash", str(kit / "check.sh"), str(repo.root)], repo, timeout=300)
    show(result.stdout + result.stderr)
    if result.returncode != 0:
        raise Failure(f"{kit}/check.sh failed")


def host_shell():
    shell = Path(
        os.environ.get("FOAMY_HOST_45") or (Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell")
    )
    return shell if (shell / "Commons").is_dir() else None


def qt_tool(name, repo, what):
    if repo.args.ci:
        raise Skip(f"--ci: {what}")
    path = QT_BIN / name
    if not os.access(path, os.X_OK):
        raise Failure(f"{path} not found: install Qt 6 (qt6-declarative); the {name} on PATH may be Qt 5's")
    return str(path)


def check_qmllint(repo):
    files = repo.by_suffix("qmllint", ".qml")
    if not files:
        raise Skip("no QML files")
    qmllint = qt_tool("qmllint", repo, "needs the host's Qt 6 qmllint, Quickshell and the Omarchy shell (qs.*)")
    shell = host_shell()
    if shell is None:
        raise Failure("the Omarchy shell (qs.* modules) was not found at /usr/share/omarchy/shell (set FOAMY_HOST_45)")
    with tempfile.TemporaryDirectory(prefix="foamy-qmllint-") as tmp:
        imports = Path(tmp) / "imports"
        imports.mkdir()
        (imports / "qs").symlink_to(shell)
        report = Path(tmp) / "report.json"
        cwd = repo.root
        if repo.kit_mode:
            # foamy-kit's kit/qmldir is generated at sync: lint a copy that has it.
            cwd = Path(tmp) / "repo"
            stage_kit(repo, cwd)
        cmd = [
            qmllint,
            *QMLLINT_FLAGS,
            "-I",
            str(imports),
            "-I",
            str(QT_BIN.parent / "qml"),
            "--json",
            str(report),
            *files,
        ]
        result = subprocess.run(cmd, cwd=cwd, env=repo.env(), capture_output=True, text=True, timeout=900)
        try:
            data = json.loads(report.read_text())
        except (OSError, ValueError):
            show(result.stdout + result.stderr)
            raise Failure("qmllint wrote no JSON report") from None
    entries = []
    for item in data.get("files", []):
        rel = os.path.relpath(item["filename"], cwd) if os.path.isabs(item["filename"]) else item["filename"]
        for warning in item.get("warnings", []):
            if warning.get("type") in ("warning", "error", "critical"):
                entries.append(
                    finding(
                        rel,
                        warning.get("id") or warning.get("type"),
                        warning.get("message", ""),
                        repo,
                        warning.get("line"),
                        base=cwd,
                    )
                )
    print(f"    {qmllint} {version_of([qmllint, '--version'])}: {len(files)} files, {len(entries)} findings")
    compare("qmllint", entries, repo)


def stage_kit(repo, target):
    """Copy foamy-kit's QML and JavaScript to `target` with the kit/qmldir
    sync generates (singletons registered), as a plugin sees them."""
    for rel in repo.files:
        if rel.endswith((".qml", ".js")) or rel.startswith("kit/"):
            (target / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo.root / rel, target / rel)
    components = json.loads((repo.root / "kit/components.json").read_text())
    lines = []
    for spec in components.values():
        for file in spec["files"]:
            if file.endswith(".qml") and "/" not in file:
                prefix = "singleton " if file[:-4] in spec.get("singletons", []) else ""
                lines.append(f"{prefix}{file[:-4]} 1.0 {file}")
    (target / "kit/qmldir").write_text("\n".join(sorted(lines)) + "\n")


def check_qmlformat(repo):
    files = repo.by_suffix("qmlformat", ".qml")
    if not files:
        raise Skip("no QML files")
    qmlformat = qt_tool("qmlformat", repo, "its output depends on the host's Qt 6 version")
    settings = repo.root / ".qmlformat.ini"
    if not settings.is_file():
        raise Failure(".qmlformat.ini is missing (foamy-kit sync.sh writes it)")
    differ = []
    for rel in files:
        result = run([qmlformat, "-s", str(settings), rel], repo, timeout=120)
        if result.returncode != 0:
            show(result.stderr)
            differ.append(f"{rel} (qmlformat failed)")
            continue
        if result.stdout != (repo.root / rel).read_text():
            differ.append(rel)
            diff = subprocess.run(
                ["diff", "-u", rel, "-"], input=result.stdout, cwd=repo.root, capture_output=True, text=True
            )
            show(diff.stdout, limit=40)
    print(f"    {qmlformat} {version_of([qmlformat, '--version'])}: {len(files)} files")
    if differ:
        raise Failure(
            f"{len(differ)} file(s) differ; format them in their own commit: {qmlformat} -s .qmlformat.ini -i <file>"
        )


def check_oxlint(repo):
    files = repo.by_suffix("oxlint", ".js", ".cjs", ".mjs")
    if not files:
        raise Skip("no JavaScript files")
    oxlint = repo.tool("oxlint")
    config = ".oxlintrc.json"
    if not (repo.root / config).is_file():
        raise Failure(".oxlintrc.json is missing (foamy-kit sync.sh writes it)")
    local = repo.root / LINT_DIR / "oxlintrc.json"
    if local.is_file():
        if "../../.oxlintrc.json" not in local.read_text():
            raise Failure(
                f'{LINT_DIR}/oxlintrc.json must extend the kit\'s config: "extends": ["../../.oxlintrc.json"]'
            )
        config = f"{LINT_DIR}/oxlintrc.json"
    # QML-loaded JavaScript starts with QML directives (`.pragma library`,
    # `.import "x.js" as X`) that are not JavaScript. Lint a copy in which they
    # are line comments, so every file parses and keeps its line numbers.
    directives = 0
    with tempfile.TemporaryDirectory(prefix="foamy-oxlint-") as tmp:
        for rel in dict.fromkeys(files + [".oxlintrc.json", config]):
            source, target = repo.root / rel, Path(tmp) / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            text = source.read_text()
            if rel.endswith(".js"):
                text, count = re.subn(r"(?m)^(\s*\.(?:pragma|import)\b)", r"//\1", text)
                directives += count
            target.write_text(text)
        result = subprocess.run(
            [oxlint, "-c", config, "-f", "json", *files],
            cwd=tmp,
            env=repo.env(),
            capture_output=True,
            text=True,
            timeout=300,
        )
    try:
        start = result.stdout.index("{")
        data = json.loads(result.stdout[start:])
    except ValueError:
        show(result.stdout + result.stderr)
        raise Failure("oxlint produced no JSON report") from None
    loaded = qml_loaded(repo, files)
    entries, api = [], 0
    for item in data.get("diagnostics", []):
        labels = item.get("labels") or [{}]
        line = (labels[0].get("span") or {}).get("line")
        rel, code, message = item.get("filename", "?"), item.get("code") or "parse-error", item.get("message", "")
        if rel in loaded and code == "eslint(no-unused-vars)" and top_level_function(repo, rel, line, message):
            api += 1  # QML calls it: the file's API, which Oxlint can't see used
            continue
        entries.append(finding(rel, code, message, repo, line))
    print(
        f"    oxlint {repo.pins['oxlint']}: {len(files)} files ({directives} QML directive line(s) read as comments; "
        f"{len(loaded)} QML-loaded, {api} top-level function(s) there taken as QML API), {len(entries)} findings"
    )
    compare("oxlint", entries, repo)


def qml_loaded(repo, files):
    """The JavaScript files QML loads: imported by a QML file (`import "x.js"
    as X`) or another loaded file (`.import`), marked `.pragma library`, or
    (in foamy-kit) a kit/*.js component file."""
    wanted = set(files)
    loaded = {rel for rel in files if (repo.kit_mode and re.fullmatch(r"kit/[^/]+\.js", rel))}
    pattern = re.compile(r'^\s*\.?import\s+"([^"]+\.js)"\s+as\b', re.M)
    for rel in repo.by_suffix(None, ".qml", ".js"):
        text = (repo.root / rel).read_text(errors="replace")
        if rel.endswith(".js") and re.search(r"(?m)^\s*\.pragma\s+library\b", text):
            loaded.add(rel)
        for target in pattern.findall(text):
            path = os.path.normpath(os.path.join(os.path.dirname(rel), target))
            if path in wanted:
                loaded.add(path)
    return loaded


def top_level_function(repo, rel, line, message):
    """Whether an unused-variable finding names a function declared at the top
    level (column 0) of `rel`."""
    match = re.match(r"Function '([\w$]+)' is declared but never used", message)
    try:
        text = (repo.root / rel).read_text(errors="replace").splitlines()[int(line) - 1]
    except (OSError, IndexError, TypeError, ValueError):
        return False
    return bool(match) and re.match(rf"function\s+{re.escape(match.group(1))}\s*\(", text) is not None


def ruff_config(repo):
    local = repo.root / ".ruff.toml"
    if local.is_file():
        if not re.search(r'(?m)^extend\s*=\s*"(\./)?ruff\.toml"', local.read_text()):
            raise Failure('.ruff.toml must extend the kit\'s config: extend = "ruff.toml"')
        return ".ruff.toml"
    return "ruff.toml"


def check_ruff(repo):
    files = repo.by_suffix("ruff", ".py")
    if not files:
        raise Skip("no Python files")
    ruff = repo.tool("ruff")
    config = ruff_config(repo)
    result = run([ruff, "check", "--config", config, "--output-format", "json", "--no-cache", *files], repo)
    try:
        data = json.loads(result.stdout)
    except ValueError:
        show(result.stdout + result.stderr)
        raise Failure("ruff check produced no JSON report") from None
    entries = [
        finding(
            os.path.relpath(item["filename"], repo.root),
            item.get("code") or "syntax",
            item["message"],
            repo,
            (item.get("location") or {}).get("row"),
        )
        for item in data
    ]
    print(f"    ruff {repo.pins['ruff']} ({config}): {len(files)} files, {len(entries)} findings")
    compare("ruff", entries, repo)


def check_ruff_format(repo):
    files = repo.by_suffix("ruff-format", ".py")
    if not files:
        raise Skip("no Python files")
    ruff = repo.tool("ruff")
    result = run([ruff, "format", "--config", ruff_config(repo), "--check", "--diff", "--no-cache", *files], repo)
    if result.returncode != 0:
        show(result.stdout + result.stderr, limit=60)
        raise Failure(
            f"files differ; format them in their own commit: ruff format --config {ruff_config(repo)} <files>"
        )
    print(f"    ruff format {repo.pins['ruff']}: {len(files)} files formatted")


def check_vulture(repo):
    files = repo.by_suffix("vulture", ".py")
    if not files:
        raise Skip("no Python files")
    vulture = repo.tool("vulture")
    ignores = read_reasoned(repo.root / LINT_DIR / "vulture-ignore.txt", "name")
    cmd = [vulture, "--min-confidence", VULTURE_CONFIDENCE, *files]
    if ignores:
        cmd[1:1] = ["--ignore-names", ",".join(name for name, _ in ignores)]
    result = run(cmd, repo)
    if result.returncode not in (0, 3):  # 3: dead code found
        show(result.stdout + result.stderr)
        raise Failure("vulture failed")
    entries = []
    for line in result.stdout.splitlines():
        match = re.match(r"(.+?):(\d+): (.+?) \(\d+% confidence", line)
        if match:
            entries.append(finding(match.group(1), "vulture", match.group(3), repo, match.group(2)))
    print(
        f"    vulture {repo.pins['vulture']}: {len(files)} files, {len(ignores)} reviewed entry point name(s), "
        f"{len(entries)} findings"
    )
    compare("vulture", entries, repo)


def check_shellcheck(repo):
    files = repo.shell_files("shellcheck")
    if not files:
        raise Skip("no shell scripts")
    syntax = []
    for rel in files:
        result = run(["bash", "-n", rel], repo, timeout=60)
        if result.returncode != 0:
            syntax.append(rel)
            show(result.stderr)
    shellcheck = repo.tool("shellcheck")
    result = run([shellcheck, "-x", "--source-path=SCRIPTDIR", "-f", "json1", *files], repo)
    try:
        data = json.loads(result.stdout)
    except ValueError:
        show(result.stdout + result.stderr)
        raise Failure("shellcheck produced no JSON report") from None
    entries = [
        finding(item["file"], f"SC{item['code']}", item["message"], repo, item.get("line"))
        for item in data.get("comments", [])
    ]
    print(f"    bash -n and shellcheck {repo.pins['shellcheck']}: {len(files)} scripts, {len(entries)} findings")
    if syntax:
        raise Failure("bash -n: syntax errors in " + ", ".join(syntax))
    compare("shellcheck", entries, repo)


def check_shfmt(repo):
    files = repo.shell_files("shfmt")
    if not files:
        raise Skip("no shell scripts")
    shfmt = repo.tool("shfmt")
    result = run([shfmt, *SHFMT_FLAGS, "-d", *files], repo)
    if result.returncode != 0:
        show(result.stdout + result.stderr, limit=60)
        raise Failure(f"scripts differ; format them in their own commit: shfmt {' '.join(SHFMT_FLAGS)} -w <files>")
    print(f"    shfmt {repo.pins['shfmt']} {' '.join(SHFMT_FLAGS)}: {len(files)} scripts formatted")


def check_native(repo):
    pins = sorted(p.parent.name for p in repo.root.glob("*/native.pin"))
    if not pins:
        raise Skip("no native helper")
    if repo.args.fast:
        raise Skip("--fast")
    if (
        repo.args.ci
        and "FoamyNative" in (repo.root / LOCK_NAME).read_text()
        and (repo.root / ".github/workflows/verify-native.yml").is_file()
    ):
        raise Skip("--ci: verify-native.yml runs build-native.sh --test for every crate")
    if not shutil.which("rustup"):
        raise Failure("rustup not found (build-native.sh --test needs the toolchain in rust-toolchain.toml)")
    failed = []
    for crate in pins:
        print(f"    build-native.sh . --test --crate {crate}")
        result = run(["bash", "kit/native/build-native.sh", ".", "--test", "--crate", crate], repo, timeout=3600)
        show(result.stdout + result.stderr, limit=60 if result.returncode else 8)
        if result.returncode != 0:
            failed.append(crate)
    if failed:
        raise Failure("build-native.sh --test failed for " + ", ".join(failed))


def check_suite(repo):
    if repo.args.update_baseline is not None:
        raise Skip("--update-baseline")
    if not (repo.root / SUITE).is_file():
        raise Failure(
            f"{SUITE} is missing: the repository's own tests (node, Python, offscreen runtime) run "
            "from it; create it (see foamy-kit README, Tooling)"
        )
    repo.tool("node")  # the suite's node tests run on the pinned node
    flags = (["--ci"] if repo.args.ci else []) + (["--fast"] if repo.args.fast else [])
    print(f"    bash {SUITE} {' '.join(flags)}".rstrip(), flush=True)
    result = subprocess.run(["bash", SUITE, *flags], cwd=repo.root, env=repo.env())
    if result.returncode != 0:
        raise Failure(f"{SUITE} failed (exit {result.returncode})")


def version_of(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return (out.stdout + out.stderr).strip().splitlines()[0].split()[-1]
    except (OSError, subprocess.SubprocessError, IndexError):
        return "?"


CHECKS = [
    ("kit-check", check_kit, "bash tests/kit-check.sh: the stamped kit files are unedited"),
    ("plugin-validate", check_plugin_validate, "omarchy-plugin-validate <plugin> (host)"),
    (
        "design-lint",
        check_design_lint,
        "foamy-kit check.sh <plugin>: kit files, versions and the design lint (FOAMY_KIT)",
    ),
    ("qmllint", check_qmllint, "Qt 6 qmllint with the Quickshell and Omarchy shell imports; baseline (host)"),
    ("qmlformat", check_qmlformat, "Qt 6 qmlformat with .qmlformat.ini, compared with each file (host)"),
    ("oxlint", check_oxlint, "Oxlint over all JavaScript, QML directives read as comments; baseline"),
    ("ruff", check_ruff, "ruff check (ruff.toml, or .ruff.toml extending it); baseline"),
    ("ruff-format", check_ruff_format, "ruff format --check"),
    (
        "vulture",
        check_vulture,
        f"Vulture --min-confidence {VULTURE_CONFIDENCE}, tests/lint/vulture-ignore.txt; baseline",
    ),
    ("shellcheck", check_shellcheck, "bash -n and ShellCheck on the repository's shell scripts; baseline"),
    ("shfmt", check_shfmt, "shfmt " + " ".join(SHFMT_FLAGS) + " -d"),
    ("native", check_native, "kit/native/build-native.sh . --test for each crate with a native.pin"),
    ("suite", check_suite, f"bash {SUITE} [--ci] [--fast]: the repository's own tests"),
]
BASELINED = ("qmllint", "oxlint", "ruff", "vulture", "shellcheck")


def names(value, allowed):
    chosen = [n.strip() for n in value.split(",") if n.strip()]
    unknown = [n for n in chosen if n not in allowed]
    if unknown:
        raise SystemExit(f"validate: unknown check(s): {', '.join(unknown)}; known: {', '.join(allowed)}")
    return chosen


def main(argv=None):
    if sys.version_info < (3, 11):
        print("validate: needs Python 3.11 or newer", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(prog="tests/validate.sh", description="Run every check of this repository.")
    parser.add_argument("--ci", action="store_true", help="no Quickshell runtime and no Omarchy host (GitHub CI)")
    parser.add_argument("--fast", action="store_true", help="skip the native helper tests; pass --fast to the suite")
    parser.add_argument("--only", help="comma-separated checks to run")
    parser.add_argument("--skip", help="comma-separated checks not to run")
    parser.add_argument(
        "--update-baseline",
        nargs="?",
        const="",
        metavar="CHECKS",
        help="rewrite tests/lint/<check>-baseline.txt from the current findings ("
        + ", ".join(BASELINED)
        + "; default all), then review the diff",
    )
    parser.add_argument("--list", action="store_true", help="list the checks")
    args = parser.parse_args(argv)
    all_names = [name for name, _, _ in CHECKS]
    if args.list:
        for name, _, what in CHECKS:
            print(f"{name:16} {what}")
        return 0
    selected = names(args.only, all_names) if args.only else list(all_names)
    if args.skip:
        skipped = names(args.skip, all_names)
        selected = [n for n in selected if n not in skipped]
    if args.update_baseline is not None:
        update = names(args.update_baseline, BASELINED) if args.update_baseline else list(BASELINED)
        selected = [n for n in selected if n in update]
    try:
        repo = Repo(ROOT, args)
    except Failure as error:
        print(f"validate: FAIL {error}", file=sys.stderr)
        return 1
    repo.update = update if args.update_baseline is not None else []
    mode = "--ci" if args.ci else "--fast" if args.fast else "full"
    print(f"validate: {repo.root.name} ({'foamy-kit' if repo.kit_mode else 'plugin'}, {mode})")
    results = []
    for name, func, _ in CHECKS:
        if name not in selected:
            continue
        print(f"== {name}", flush=True)
        try:
            func(repo)
            results.append((name, "PASS", ""))
        except Skip as reason:
            print(f"    skipped: {reason}")
            results.append((name, "SKIP", str(reason)))
        except Failure as error:
            print(f"    FAIL: {error}")
            results.append((name, "FAIL", str(error)))
        except subprocess.TimeoutExpired as error:
            results.append((name, "FAIL", f"timed out: {error.cmd[0]}"))
        sys.stdout.flush()
    print("\nvalidate summary:")
    for name, status, detail in results:
        print(f"  {status}  {name}" + (f": {detail}" if detail else ""))
    failed = [name for name, status, _ in results if status == "FAIL"]
    print(f"validate: {'FAILED: ' + ', '.join(failed) if failed else 'OK'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
