"""Bound clipboard producers in real subprocesses and exercise the QML editor."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "components/clipboard.sh"
MOCK = '''#!/usr/bin/python3
import json, os, signal, sys, time
from pathlib import Path
state = Path(os.environ["TEST_CLIPBOARD_STATE"])
if Path(sys.argv[0]).name == "clipboard-fixture":
    state.write_text(sys.argv[1])
    sys.exit(0)
mode = state.read_text()
Path(str(state) + ".pid").write_text(str(os.getpid()))
Path(str(state) + ".args").write_text(json.dumps(sys.argv[1:]))
if mode == "failure": sys.exit(1)
if mode == "ignore":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)
if mode == "stall": time.sleep(30)
if mode in ("stream", "slow"):
    while True:
        os.write(1, b"x" * (4096 if mode == "stream" else 1))
        if mode == "slow": time.sleep(0.1)
if mode == "delayed": time.sleep(0.4)
values = {"normal": "folder", "unicode": "/home/test/Blåbær 📁",
          "empty": "", "limit": "x" * 16384, "large": "x" * 16385,
          "nul": "a\\x00b", "lines": "one\\r\\ntwo\\u2028three",
          "delayed": "later", "long": "x" * 400}
os.write(1, values.get(mode, "folder").encode())
'''


class ClipboardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.state = self.base / "state"
        self.state.write_text("normal")
        for name in ("wl-paste", "clipboard-fixture"):
            path = self.base / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.env = dict(os.environ, TEST_CLIPBOARD_STATE=str(self.state),
                        PATH=f"{self.base}:{os.environ['PATH']}")

    def read(self, mode, selection="clipboard"):
        self.state.write_text(mode)
        started = time.monotonic()
        result = subprocess.run(["bash", str(HELPER), selection], env=self.env,
                                capture_output=True, timeout=5)
        self.assertLess(time.monotonic() - started, 4)
        self.assertLessEqual(len(result.stdout), 100000)
        return result

    def test_settings_use_safe_editor(self):
        settings = (ROOT / "components/SettingsField.qml").read_text() + (ROOT / "Panel.qml").read_text()
        editor = (ROOT / "components/SafeTextField.qml").read_text()
        self.assertIn("SafeTextField {", settings)
        self.assertNotIn("Controls.TextField {", settings)
        self.assertIn("Controls.TextArea.flickable", editor)
        self.assertNotIn("editor.paste()", editor)
        self.assertNotIn("editor.canPaste", editor)

    def test_unicode_empty_and_limit(self):
        for mode, expected in (("unicode", "/home/test/Blåbær 📁"),
                               ("empty", ""), ("limit", "x" * 16384)):
            with self.subTest(mode=mode):
                result = self.read(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_primary_selection_and_single_line(self):
        result = self.read("lines", "primary")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "one  two three")
        args = json.loads(Path(str(self.state) + ".args").read_text())
        self.assertEqual(args, ["--no-newline", "--type", "text", "--primary"])

    def test_oversized_nul_and_continuous_stream_are_rejected(self):
        for mode in ("large", "nul", "stream"):
            with self.subTest(mode=mode):
                result = self.read(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"")

    def test_total_deadline_covers_stalled_and_slow_sources(self):
        for mode in ("stall", "slow"):
            with self.subTest(mode=mode):
                result = self.read(mode)
                self.assertEqual(result.returncode, 137)

    def test_failure_and_invalid_selection(self):
        self.assertNotEqual(self.read("failure").returncode, 0)
        self.assertEqual(self.read("normal", "invalid").returncode, 2)

    def test_producer_ignoring_term_is_killed(self):
        result = self.read("ignore")
        self.assertEqual(result.returncode, 137)
        self.assert_producer_stopped()

    def assert_producer_stopped(self):
        pid = Path(str(self.state) + ".pid").read_text()
        status = Path(f"/proc/{pid}/stat")
        # The group leader can close stdout before a killed child is scheduled
        # to exit. Observe the child's state with a bounded wait, without the
        # exists/read race when /proc removes it between those two operations.
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try:
                state = status.read_text().split()[2]
            except FileNotFoundError:
                return
            if state == "Z":
                return
            time.sleep(0.01)
        self.fail("clipboard producer survived its deadline")

    def test_watchdog_survives_wrapper_destruction(self):
        self.state.write_text("stall")
        with subprocess.Popen(["bash", str(HELPER), "clipboard"], env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            pid_file = Path(str(self.state) + ".pid")
            deadline = time.monotonic() + 2
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(pid_file.exists(), "clipboard producer did not start")
            process.kill()
            process.communicate(timeout=4)
        self.assert_producer_stopped()

    def test_qml_editing_and_paste(self):
        runner = shutil.which("qs")
        if not runner:
            self.skipTest("Quickshell is unavailable")
        # Quickshell's statically registered Io plugin requires the qs executable.
        # A stock qmltestrunner cannot load it as a dynamic QML plugin.
        fixture = self.base / "shell.qml"
        fixture.write_text('''import QtQuick
import Quickshell
ShellRoot {
    FloatingWindow {
        title: "Foamy clipboard tests"
        visible: true
        implicitWidth: 500
        implicitHeight: 250
        Loader { anchors.fill: parent; source: %s }
    }
}
''' % json.dumps(str(ROOT / "tests/tst_clipboard.qml")))
        runtime = self.base / "runtime"
        runtime.mkdir(mode=0o700)
        env = dict(self.env, QT_QPA_PLATFORM=os.environ.get("FOAMY_TEST_PLATFORM", "offscreen"),
                   QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="",
                   XDG_RUNTIME_DIR=str(runtime))
        if env["QT_QPA_PLATFORM"] == "wayland":
            # Keep test logs/IPC private without hiding the host compositor socket.
            display = Path(os.environ["WAYLAND_DISPLAY"])
            if not display.is_absolute():
                env["WAYLAND_DISPLAY"] = str(Path(os.environ["XDG_RUNTIME_DIR"]) / display)
        result = subprocess.run([runner, "-p", str(fixture), "--no-color"],
                                env=env, text=True, capture_output=True, timeout=35)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertRegex(output, r"CLIPBOARD_RESULT passed=[1-9][0-9]* failed=0")
        self.assertIn("failed=0", output, output)
        print(output[output.index("CLIPBOARD_RESULT"):].splitlines()[0])


if __name__ == "__main__":
    unittest.main()
