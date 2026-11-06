"""The favicon lookup, run as a process: the plugin helper's `favicon` subcommand.

FOAMY_HELPER (a JSON argv prefix) selects the helper; the default is this
plugin's own bin/<machine>/foamy-<x>-helper (manifest id foamy.<x>). The
copy-guard, journal and corruption internals are unit-tested in foamy-kit
(kit/rust/foamy-helper/src/favicon/tests.rs).
"""
from contextlib import closing
import json
import os
from pathlib import Path
import platform
import sqlite3
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]


def helper():
    configured = os.environ.get('FOAMY_HELPER')
    if configured:
        return json.loads(configured)
    plugin = json.loads((ROOT / 'manifest.json').read_text())['id'].split('.', 1)[1]
    return [str(ROOT / 'bin' / platform.machine() / f'foamy-{plugin}-helper')]


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0\x50\x80\xF0\xFF')) + chunk(b'IEND', b'')


class FaviconTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config'
        self.env = {'HOME': str(self.root / 'home'), 'XDG_CONFIG_HOME': str(self.config), 'XDG_CACHE_HOME': str(self.root / 'cache')}

    def database(self, rows):
        path = self.config / 'vivaldi/Profile 1/Favicons'
        path.parent.mkdir(parents=True)
        with closing(sqlite3.connect(path)) as db:
            db.executescript('CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER); CREATE INDEX urls ON icon_mapping(page_url); CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER, height INTEGER, last_updated INTEGER);')
            for i, (url, data) in enumerate(rows):
                db.execute('INSERT INTO icon_mapping VALUES (?, ?)', (url, i))
                db.execute('INSERT INTO favicon_bitmaps VALUES (?, ?, 32, 32, 100)', (i, data))
            db.commit()
        return path

    def run_helper(self, request):
        return subprocess.run(helper() + ['favicon'], input=json.dumps(request), capture_output=True, text=True, env={**os.environ, **self.env}, timeout=4)

    def lookup(self, host='example.com', browser='vivaldi'):
        result = self.run_helper({'browser': browser, 'hostname': host})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_locked_cache_extracts_without_changing_or_unlocking_browser_files(self):
        path = self.database([('https://example.com/mail', png())])
        before = path.read_bytes()
        with closing(sqlite3.connect(path)) as browser:
            browser.execute('PRAGMA locking_mode=EXCLUSIVE')
            browser.execute('BEGIN EXCLUSIVE')
            browser.commit()
            response = self.lookup()
            self.assertEqual(response['status'], 'found')
            self.assertEqual(Path(response['source'].removeprefix('file://')).read_bytes(), png())
            # A separate reader must still see the browser's exclusive lock.
            result = subprocess.run(['python3', '-c', 'import sqlite3,sys; db=sqlite3.connect(sys.argv[1],timeout=0); db.execute("SELECT * FROM icon_mapping").fetchall()', str(path)], capture_output=True, text=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('database is locked', result.stderr)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(path.parent.iterdir()), [path])

    def test_uncommitted_browser_transaction_is_not_copied(self):
        path = self.database([('https://example.com/', png())])
        before = path.read_bytes()
        with closing(sqlite3.connect(path)) as browser:
            browser.execute('BEGIN EXCLUSIVE')
            browser.execute('UPDATE favicon_bitmaps SET image_data = ?', (b'uncommitted',))
            self.assertGreater(Path(str(path) + '-journal').stat().st_size, 0)
            self.assertEqual(self.lookup(), {'source': '', 'status': 'cache-unavailable'})
            browser.rollback()
        self.assertEqual(path.read_bytes(), before)

    def test_locked_cache_with_transaction_sidecars_falls_back(self):
        path = self.database([('https://example.com/', png())])
        with closing(sqlite3.connect(path)) as browser:
            browser.execute('PRAGMA locking_mode=EXCLUSIVE')
            browser.execute('BEGIN EXCLUSIVE')
            browser.commit()
            for suffix, data in [('-journal', b'active journal'), ('-wal', b''), ('-shm', b'')]:
                sidecar = Path(str(path) + suffix)
                sidecar.write_bytes(data)
                self.assertEqual(self.lookup(), {'source': '', 'status': 'cache-unavailable'})
                self.assertEqual(sidecar.read_bytes(), data)
                sidecar.unlink()

    def test_wal_cache_is_read_including_committed_wal_pages(self):
        path = self.database([])
        with closing(sqlite3.connect(path)) as browser:
            browser.execute('PRAGMA journal_mode=WAL')
            browser.execute('INSERT INTO icon_mapping VALUES (?, 1)', ('https://example.com/',))
            browser.execute('INSERT INTO favicon_bitmaps VALUES (1, ?, 32, 32, 100)', (png(),))
            browser.commit()
            self.assertGreater(Path(str(path) + '-wal').stat().st_size, 0)
            self.assertEqual(self.lookup()['status'], 'found')

    def test_real_helper_extracts_private_png_and_reuses_cache(self):
        database = self.database([('https://teams.microsoft.com/chat', png())])
        response = self.lookup('teams.microsoft.com')
        self.assertEqual(response['status'], 'found')
        icon = Path(response['source'].removeprefix('file://'))
        self.assertEqual(icon.read_bytes(), png())
        self.assertEqual(icon.stat().st_mode & 0o777, 0o600)
        database.unlink()
        self.assertEqual(self.lookup('teams.microsoft.com')['status'], 'cached')

    def test_hostname_bounds_do_not_match_other_sites_or_remote_icons(self):
        self.database([('https://teams.microsoft.com.evil.invalid/chat', png()), ('https://other.example.com/', png())])
        self.assertEqual(self.lookup('teams.microsoft.com')['source'], '')
        for host in ['../secret', 'https://example.com', 'example.com:443', 'example.com\nother.com']:
            result = self.run_helper({'browser': 'vivaldi', 'hostname': host})
            self.assertEqual(result.returncode, 1, host)
            self.assertEqual(json.loads(result.stdout), {'source': '', 'status': 'error'})
        self.assertEqual(self.lookup('example.com', 'firefox')['status'], 'unsupported-browser')

    def test_missing_corrupt_and_oversized_icons_fall_back(self):
        self.assertEqual(self.lookup()['source'], '')
        path = self.database([('https://example.com/', b'x' * 65537), ('http://example.com/', b'not a PNG')])
        self.assertEqual(self.lookup()['source'], '')
        path.write_bytes(b'corrupt database')
        self.assertEqual(self.lookup()['source'], '')


if __name__ == '__main__':
    unittest.main()
