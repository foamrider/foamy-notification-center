import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import hostenv  # noqa: E402  (foamy-kit's preview/hostenv.py)


# Test double of the host's omarchy-hyprland-focus-app (same contract): focus the
# newest window whose class matches, through the test's own hyprctl stub.
def focus_app(log):
    return (
        '#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "' + str(log) + '"\n'
        'address=$(hyprctl clients -j 2>/dev/null | jq -r --arg p "$1" \'def m($v): ($v // "") | test($p; "i"); '
        'sort_by(.focusHistoryID) | first((.[] | select(m(.class))), (.[] | select(.initialClass == "org.omarchy.agent" and m(.initialTitle)))).address // empty\')\n'
        "[[ -n $address ]] || exit 1\n"
        'hyprctl dispatch "hl.dsp.focus({ window = \\"address:$address\\" })"\n'
    )


if "--inside" not in sys.argv:
    raise SystemExit(
        subprocess.run(
            ["dbus-run-session", "--", "python3", __file__, "--inside", *sys.argv[1:]], timeout=150
        ).returncode
    )
custom = "--custom" in sys.argv
base = Path(tempfile.mkdtemp(prefix="foamy-stock-review-"))
app = base / "app"
app.mkdir()
home = base / "home"
home.mkdir()
runtime = base / "runtime"
runtime.mkdir(mode=0o700)
for n in ["Commons", "Ui"]:
    (app / n).symlink_to(hostenv.root() / "shell" / n, target_is_directory=True)
# The host's stock notifications QML (QML only; no host script is ever run).
shutil.copytree(hostenv.root() / "shell/plugins/notifications", app / "stock")
p = app / "stock/Service.qml"
s = p.read_text()
p.write_text(s[: s.rfind("  Variants {")] + "}\n")
shutil.copytree(Path(__file__).resolve().parents[1], app / "center", ignore=shutil.ignore_patterns(".git"))
(app / "shell.qml").write_text("""import QtQuick
import Quickshell
import Quickshell.Io
import "stock" as Stock
import "center" as Center
ShellRoot {Stock.Service {id:stock} Center.Service {id:center}
 IpcHandler {target:"review";function mark():void{center.markSeen()} function toggle():void{center.toggleDnd()} function focus():void{center.focusNotification(center.entries[0])} }
}""")
bin = base / "bin"
bin.mkdir()
cli = bin / "omarchy-shell"
cli.write_text('#!/bin/sh\n[ "$1" = "-q" ] && shift\nexec qs ipc -n -p ' + str(app) + ' call "$@"\n')
cli.chmod(0o755)
# The real stock focus helper talks only to this isolated window fixture.
clients = base / "clients.json"
clients.write_text("{broken JSON")
dispatches = base / "dispatches"
(bin / "hyprctl").write_text(
    "#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\nif sys.argv[1]=='clients':print(Path("
    + repr(str(clients))
    + ").read_text())\nelse:Path("
    + repr(str(dispatches))
    + ").write_text('focused')\n"
)
(bin / "hyprctl").chmod(0o755)
state = base / "custom-state" if custom else home / ".local/state"
env = dict(
    os.environ,
    HOME=str(home),
    XDG_CONFIG_HOME=str(home / ".config"),
    XDG_STATE_HOME=str(state),
    XDG_RUNTIME_DIR=str(runtime),
    QT_QPA_PLATFORM="offscreen",
    QT_QUICK_BACKEND="software",
    QT_QPA_PLATFORMTHEME="basic",
)
for k in ["DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"]:
    env.pop(k, None)
# OMARCHY_PATH exposes only the host's shell/ and default/; omarchy-* are stubs (the stock
# focus fallback runs the omarchy-hyprland-focus-app test double, never a host script).
# The re-exec above put this process inside dbus-run-session: notify-send
# and qs share that private bus, never the desktop's.
hostenv.isolate(env, base, session_bus=os.environ["DBUS_SESSION_BUS_ADDRESS"])
env.update(
    hostenv.make(
        base,
        app,
        env=env,
        stubs={"omarchy-hyprland-focus-app": focus_app(base / hostenv.CALLS_LOG)},
        names=("omarchy-notification-send",),
    )
)
env["PATH"] = str(bin) + ":" + env["PATH"]
log = (base / "log").open("w")
# Its own process group: stop() also ends the scripts its Processes started.
proc = hostenv.ProcessGroup(["qs", "-p", str(app), "--no-color"], env=env, stdout=log, stderr=log)


def ipc(t, *args):
    return subprocess.check_output(
        ["qs", "ipc", "-n", "-p", str(app), "call", t, *args], env=env, text=True, timeout=3
    ).strip()


def status():
    return json.loads(ipc("foamy.notification-center.test", "state"))


def wait(fn, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if fn():
                return
        except Exception:
            pass
        time.sleep(0.1)
    raise AssertionError((base / "log").read_text())


# The service runs one DND command at a time and ignores a toggle meanwhile (a
# read follows every toggle and every dndChanged event), so a toggle waits for
# the previous command to end.
def toggle():
    wait(lambda: not status()["dndBusy"])
    ipc("review", "toggle")


# The center's toggle until the daemon is `on`: a toggle that met a read starting
# in between is ignored and retried (never one while a toggle runs, so none flips
# back), then the center shows the daemon's state.
def center_dnd(on):
    assert ipc("notifications", "isDnd") != ("on" if on else "off")
    end = time.monotonic() + 30
    while ipc("notifications", "isDnd") != ("on" if on else "off"):
        assert time.monotonic() < end, (base / "log").read_text()
        toggle()
        try:
            wait(lambda: ipc("notifications", "isDnd") == ("on" if on else "off"), timeout=3)
        except AssertionError:
            pass
        wait(lambda: not status()["dndBusy"])
    wait(lambda: status()["doNotDisturb"] == on and not status()["dndError"])


def send(title, replace=None):
    return subprocess.check_output(
        [
            "notify-send",
            "-p",
            "-a",
            "Stock Review",
            "-u",
            "critical",
            *(["-r", replace] if replace else []),
            title,
            "Synthetic compatibility check",
        ],
        env=env,
        text=True,
        timeout=3,
    ).strip()


try:
    wait(lambda: ipc("notifications", "ping") == "ok" and status()["loaded"])
    # Foamy Notifications calls the store target by name. The bare
    # `foamy.notification-center` target belongs to the Panel (users bind
    # keys to its open/close), so the service must not register it.
    shown = subprocess.check_output(["qs", "ipc", "-n", "-p", str(app), "show"], env=env, text=True, timeout=3)
    targets = {line.split()[1] for line in shown.splitlines() if line.startswith("target ")}
    assert {"foamy.notification-center.store", "foamy.notification-center.test"} <= targets, shown
    assert "foamy.notification-center" not in targets, shown
    reply = ipc("foamy.notification-center.store", "remove", "../x")
    assert reply == "error: invalid keys", f"remove ../x answered {reply!r}"
    reply = ipc("foamy.notification-center.store", "peerChanged", "nope")
    assert reply == "error: unknown", f"peerChanged nope answered {reply!r}"
    first = send("Stock before")
    wait(lambda: status()["newest"] == "Stock before")
    send("Stock replaced", first)
    wait(lambda: status()["newest"] == "Stock replaced")
    assert status()["entries"] == 1
    ipc("notifications", "dismissAll")
    ipc("notifications", "toggleDnd")
    wait(lambda: status()["doNotDisturb"])
    ipc("notifications", "toggleDnd")
    wait(lambda: not status()["doNotDisturb"])
    ipc("review", "mark")
    wait(lambda: status()["unread"] == 0)
    center_dnd(True)
    send("Stock silenced")
    # 2, not 1: the daemon's dismissAll above did not remove "Stock replaced"
    # from the history. The watcher handles the daemon's writes in order, so
    # this later arrival is the barrier for the dismissal.
    wait(lambda: status()["entries"] == 2)
    center_dnd(False)
    ipc("foamy.notification-center.test", "clear")
    wait(lambda: status()["entries"] == 0)
    send("After clear")
    wait(lambda: status()["entries"] == 1)
    # Focus, a shell that cannot start and the watcher backoff use no state
    # path: the --custom run, which checks only the paths, leaves them out.
    if not custom:
        ipc("review", "focus")
        wait(lambda: bool(status()["focusError"]))
        assert status()["entries"] == 1
        clients.write_text(json.dumps([{"class": "Stock Review", "address": "0x123"}]))
        ipc("review", "focus")
        wait(lambda: status()["entries"] == 0)
        assert dispatches.read_text() == "focused"
        assert not status()["focusError"]
        # An omarchy-shell that can't start (its interpreter is missing: exec fails, so
        # Quickshell emits no exited()). The stubs stay first on PATH, so no host
        # omarchy-shell is ever reached. The click still gets the stock focus
        # fallback; the DND toggle shows its error.
        shells = [
            path / "omarchy-shell" for path in map(Path, env["PATH"].split(":")) if (path / "omarchy-shell").exists()
        ][:2]
        assert shells == [bin / "omarchy-shell", Path(env["PATH"].split(":")[1]) / "omarchy-shell"], shells
        saved = [(path, path.read_text()) for path in shells]
        for path in shells:
            path.write_text("#!/nonexistent/omarchy-shell-interpreter\n")
        send("Shell missing")
        wait(lambda: status()["entries"] == 1)
        ipc("review", "focus")
        wait(lambda: status()["entries"] == 0)
        assert not status()["focusError"]
        assert not status()["dndError"]
        assert "Process failed to start" in (base / "log").read_text(), "omarchy-shell did start"
        toggle()
        wait(lambda: bool(status()["dndError"]) and not status()["dndBusy"])
        assert not status()["doNotDisturb"]
        for path, text in saved:
            path.write_text(text)
            path.chmod(0o755)
        center_dnd(True)
        center_dnd(False)
        # A watcher that dies at every start (here: inotifywait exits at once) backs
        # off 1 s, 2 s, 4 s rather than looping at 1 Hz, and recovers. The exact
        # schedule is checked with a controlled clock in integration.test.js; this
        # checks the real wiring. Each start of the fake inotifywait writes a stamp.
        helper = str(app / "center/bin" / os.uname().machine / "foamy-notification-center-helper")

        def watchers():
            found = []
            for entry in Path("/proc").iterdir():
                try:
                    if entry.name.isdigit() and (entry / "cmdline").read_bytes().split(b"\0")[:2] == [
                        helper.encode(),
                        b"watch",
                    ]:
                        found.append(int(entry.name))
                except OSError:
                    pass
            return found

        stamps = base / "inotify-starts"

        def starts():
            return [float(line) for line in stamps.read_text().split()] if stamps.exists() else []

        wait(lambda: len(watchers()) == 1 and status()["watching"])
        fake = bin / "inotifywait"
        fake.write_text('#!/bin/sh\ndate +%s.%N >> "' + str(stamps) + '"\nexit 1\n')
        fake.chmod(0o755)
        os.kill(watchers()[0], signal.SIGTERM)
        wait(lambda: len(starts()) >= 3, timeout=20)
        # The starts come about 2 s and then 4 s apart. A 1 Hz loop gives 1 s, and a
        # backoff that does not double gives 2 s. Load can only make a gap longer.
        found = starts()
        assert found[2] - found[1] >= 3, f"watcher starts at {[round(t - found[0], 2) for t in found]} s"
        fake.unlink()
        wait(lambda: status()["watching"] and len(watchers()) == 1, timeout=12)
        send("After watcher recovery")
        wait(lambda: status()["newest"] == "After watcher recovery")
    stock = "stock: delivery, in-place replacement, dismissal history, read state, DND both ways, silenced history, clear and subsequent arrival"
    if custom:
        print("PASS with a custom XDG_STATE_HOME; " + stock)
    else:
        print(
            "PASS stock default-action fallback, failed focus retention and retry; "
            + stock
            + "; Foamy Notifications absent; a missing omarchy-shell: focus fallback and DND error; watcher restart backoff and recovery"
        )
except BaseException:
    # A failed run keeps its files to see what failed.
    print("Evidence:", base)
    raise
finally:
    proc.stop()
    log.close()
    hostenv.check(env, (base / "log").read_text(), *hostenv.calls(base))
shutil.rmtree(base)
