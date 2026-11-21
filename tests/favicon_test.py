"""Browser favicons from local Chromium caches, run as a process (`<helper> favicon`).

Shared verbatim with foamy-notification-center (tests/shared-files.sha256).
FOAMY_HELPER is the helper's argv prefix as a JSON list of absolute paths; the
test appends `favicon`. The default is this plugin's bundled binary,
bin/<machine>/<manifest id with "." as "-">-helper (foamy-kit FoamyNative).
"""

from contextlib import closing
import json
import os
from pathlib import Path
import platform
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]


def helper_prefix():
    if os.environ.get("FOAMY_HELPER"):
        return json.loads(os.environ["FOAMY_HELPER"])
    plugin = json.loads((ROOT / "manifest.json").read_text())["id"]
    return [str(ROOT / "bin" / platform.machine() / (plugin.replace(".", "-") + "-helper"))]


def png(width=1, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"\0\x50\x80\xf0\xff"))
        + chunk(b"IEND", b"")
    )


class FaviconTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config"
        self.cache = self.root / "cache/foamy/browser-favicons"
        self.scratch = self.root / "tmp"
        self.scratch.mkdir()
        self.env = {
            "PATH": "/nonexistent",
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.scratch),
            "XDG_CONFIG_HOME": str(self.config),
            "XDG_CACHE_HOME": str(self.root / "cache"),
        }

    def database(self, rows, profile="Profile 1", root="vivaldi", size=(32, 32)):
        path = self.config / root / profile / "Favicons"
        path.parent.mkdir(parents=True)
        with closing(sqlite3.connect(path)) as db:
            db.executescript(
                "CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER); CREATE INDEX urls ON icon_mapping(page_url); CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER, height INTEGER, last_updated INTEGER);"
            )
            for i, (url, data) in enumerate(rows):
                db.execute("INSERT INTO icon_mapping VALUES (?, ?)", (url, i))
                db.execute("INSERT INTO favicon_bitmaps VALUES (?, ?, ?, ?, 100)", (i, data, *size))
            db.commit()
        return path

    def run_helper(self, request):
        raw = request if isinstance(request, bytes) else json.dumps(request).encode()
        return subprocess.run(
            helper_prefix() + ["favicon"], input=raw, capture_output=True, env=self.env, timeout=6, cwd=self.root
        )

    def helper(self, host="example.com", browser="vivaldi"):
        result = self.run_helper({"browser": browser, "hostname": host})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count(b"\n"), 1)
        return json.loads(result.stdout)

    def failed(self, request):
        result = self.run_helper(request)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b'{"source": "", "status": "error"}\n')
        self.assertTrue(result.stderr.startswith(b"Favicon lookup failed: "), result.stderr)

    def found(self, response):
        self.assertIn(response["status"], ("found", "cached"))
        return Path(response["source"].removeprefix("file://"))

    def locked(self, path):
        """The browser's hold on its database: an exclusive lock that stays after commit."""
        browser = sqlite3.connect(path)
        browser.execute("PRAGMA locking_mode=EXCLUSIVE")
        browser.execute("BEGIN EXCLUSIVE")
        browser.commit()
        return closing(browser)

    def test_locked_cache_extracts_without_changing_or_unlocking_browser_files(self):
        path = self.database([("https://example.com/mail", png())])
        before = path.read_bytes()
        with self.locked(path):
            response = self.helper()
            self.assertEqual(response["status"], "found")
            self.assertEqual(self.found(response).read_bytes(), png())
            # A separate reader must still see the browser's exclusive lock.
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    'import sqlite3,sys; db=sqlite3.connect(sys.argv[1],timeout=0); db.execute("SELECT * FROM icon_mapping").fetchall()',
                    str(path),
                ],
                capture_output=True,
                text=True,
                timeout=2,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("database is locked", result.stderr)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(path.parent.iterdir()), [path])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_real_helper_extracts_private_png_and_reuses_cache(self):
        database = self.database([("https://teams.microsoft.com/chat", png())])
        response = self.helper("teams.microsoft.com")
        self.assertEqual(response["status"], "found")
        icon = self.found(response)
        self.assertEqual(icon.parent, self.cache)
        self.assertEqual(icon.read_bytes(), png())
        self.assertEqual(icon.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o700)
        database.unlink()
        self.assertEqual(self.helper("teams.microsoft.com"), {"source": response["source"], "status": "cached"})
        # A day-old icon is looked up again.
        os.utime(icon, (time.time() - 90000, time.time() - 90000))
        self.assertEqual(self.helper("teams.microsoft.com")["status"], "not-found")

    def test_profiles_https_first_and_the_closest_size(self):
        self.database([("http://example.com/", png(2, 2)), ("https://example.com/a", png(3, 3))], profile="Default")
        self.assertEqual(self.found(self.helper()).read_bytes(), png(3, 3))
        self.database([("https://other.example/", png(4, 4))], profile="Profile 3", root="google-chrome-beta")
        self.assertEqual(self.found(self.helper("other.example", "chrome")).read_bytes(), png(4, 4))
        self.assertEqual(self.helper("other.example", "brave")["status"], "not-found")

    def test_bad_requests_reply_with_an_error(self):
        for raw in [b"not json", b"[]", b'{"browser": "vivaldi", "hostname": "' + b"a" * 4100 + b'"}']:
            with self.subTest(raw=raw[:20]):
                self.failed(raw)


if __name__ == "__main__":
    unittest.main()
