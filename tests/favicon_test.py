from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/browser-favicon.py'
spec = importlib.util.spec_from_file_location('favicon', SCRIPT)
favicon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(favicon)


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
        self.env = {'XDG_CONFIG_HOME': str(self.config), 'XDG_CACHE_HOME': str(self.root / 'cache')}

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

    def helper(self, host='example.com'):
        result = subprocess.run(['python3', str(SCRIPT)], input=json.dumps({'browser': 'vivaldi', 'hostname': host}), capture_output=True, text=True, env={**os.environ, **self.env}, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_locked_cache_extracts_without_changing_or_unlocking_browser_files(self):
        path = self.database([('https://example.com/mail', png())])
        before = path.read_bytes()
        with closing(sqlite3.connect(path)) as browser:
            browser.execute('PRAGMA locking_mode=EXCLUSIVE')
            browser.execute('BEGIN EXCLUSIVE')
            browser.commit()
            response = self.helper()
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
            self.assertEqual(self.helper(), {'source': '', 'status': 'cache-unavailable'})
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
                response = self.helper()
                self.assertEqual(response, {'source': '', 'status': 'cache-unavailable'})
                self.assertEqual(sidecar.read_bytes(), data)
                sidecar.unlink()

    def test_guarded_copy_checks_changes_limits_and_symlinks(self):
        path = self.database([('https://example.com/', png())])
        state = favicon.snapshot_state(path)
        changed = ((state[0][0], state[0][1], state[0][2], state[0][3] + 1, state[0][4]), *state[1:])
        with patch.object(favicon, 'snapshot_state', side_effect=[state, changed, state, changed]):
            with self.assertRaises(favicon.SnapshotUnavailable):
                favicon.copy_snapshot(path, time.monotonic() + 2)
        with patch.object(favicon, 'snapshot_state', side_effect=[state, changed, state, state]):
            self.assertEqual(favicon.copy_snapshot(path, time.monotonic() + 2), path.read_bytes())
        with patch.object(favicon, 'MAX_DATABASE_BYTES', 1):
            with self.assertRaises(favicon.SnapshotUnavailable):
                favicon.copy_snapshot(path, time.monotonic() + 2)
        with self.assertRaises(favicon.SnapshotUnavailable):
            favicon.copy_snapshot(path, time.monotonic() - 1)
        alias = path.parent / 'alias'
        alias.symlink_to(path)
        with self.assertRaises(favicon.SnapshotUnavailable):
            favicon.copy_snapshot(alias, time.monotonic() + 2)
        sidecar = Path(str(path) + '-journal')
        sidecar.symlink_to(path)
        with self.assertRaises(favicon.SnapshotUnavailable):
            favicon.copy_snapshot(path, time.monotonic() + 2)

    def test_empty_persistent_journal_is_allowed_but_wal_database_header_is_not(self):
        path = self.database([('https://example.com/', png())])
        Path(str(path) + '-journal').touch()
        self.assertEqual(favicon.locked_favicon(path, 'example.com', time.monotonic() + 2), png())
        with path.open('r+b') as stream:
            stream.seek(18)
            stream.write(b'\x02\x02')
        with self.assertRaises(favicon.SnapshotUnavailable):
            favicon.locked_favicon(path, 'example.com', time.monotonic() + 2)

    def test_corrupt_copy_is_rejected_without_writing_database_copies(self):
        path = self.database([('https://example.com/', png())])
        temporary = self.root / 'temporary'
        temporary.mkdir()
        original_copy = favicon.copy_snapshot

        def corrupt(database, deadline):
            data = bytearray(original_copy(database, deadline))
            data[100] = 0xff
            return bytes(data)

        with patch.object(tempfile, 'tempdir', str(temporary)), patch.object(favicon, 'copy_snapshot', side_effect=corrupt):
            with self.assertRaises((sqlite3.Error, favicon.SnapshotUnavailable)):
                favicon.locked_favicon(path, 'example.com', time.monotonic() + 2)
        self.assertEqual(list(temporary.iterdir()), [])

    def test_wal_cache_is_read_through_sqlite_including_committed_wal_pages(self):
        path = self.database([])
        with closing(sqlite3.connect(path)) as browser:
            browser.execute('PRAGMA journal_mode=WAL')
            browser.execute('INSERT INTO icon_mapping VALUES (?, 1)', ('https://example.com/',))
            browser.execute('INSERT INTO favicon_bitmaps VALUES (1, ?, 32, 32, 100)', (png(),))
            browser.commit()
            self.assertGreater(Path(str(path) + '-wal').stat().st_size, 0)
            self.assertEqual(self.helper()['status'], 'found')

    def test_real_helper_extracts_private_png_and_reuses_cache(self):
        database = self.database([('https://teams.microsoft.com/chat', png())])
        env = {**os.environ, **self.env}
        result = subprocess.run(['python3', str(SCRIPT)], input=json.dumps({'browser':'vivaldi','hostname':'teams.microsoft.com'}), capture_output=True, text=True, env=env, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response['status'], 'found')
        icon = Path(response['source'].removeprefix('file://'))
        self.assertEqual(icon.read_bytes(), png())
        self.assertEqual(icon.stat().st_mode & 0o777, 0o600)
        self.assertEqual(database.stat().st_size > 0, True)
        database.unlink()
        with patch.dict(os.environ, self.env):
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'teams.microsoft.com'})['status'], 'cached')

    def test_hostname_bounds_do_not_match_other_sites_or_remote_icons(self):
        self.database([('https://teams.microsoft.com.evil.invalid/chat', png()), ('https://other.example.com/', png())])
        with patch.dict(os.environ, self.env):
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'teams.microsoft.com'})['source'], '')
            for host in ['../secret','https://example.com','example.com:443','example.com\nother.com']:
                with self.assertRaises(ValueError):
                    favicon.resolve({'browser':'vivaldi','hostname':host})
            self.assertEqual(favicon.resolve({'browser':'firefox','hostname':'example.com'})['status'], 'unsupported-browser')

    def test_missing_corrupt_and_oversized_icons_fall_back(self):
        with patch.dict(os.environ, self.env):
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'example.com'})['source'], '')
            path = self.database([('https://example.com/', b'x'*65537), ('http://example.com/', b'not a PNG')])
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'example.com'})['source'], '')
            path.write_bytes(b'corrupt database')
            self.assertEqual(favicon.resolve({'browser':'vivaldi','hostname':'example.com'})['source'], '')
        data = bytearray(png())
        data[16:20] = struct.pack('>I', 99999)
        self.assertFalse(favicon.valid_png(bytes(data)))


if __name__ == '__main__':
    unittest.main()
